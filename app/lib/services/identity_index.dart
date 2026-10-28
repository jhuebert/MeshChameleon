import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

/// Current on-disk identity index schema.
///
/// Version 2 adds the per-identity `enabled` flag. Version 1 catalogs are read
/// as enabled and upgraded on the next load.
const int identityIndexVersion = 2;

/// Thrown when the identity catalog exists but cannot be read safely.
///
/// The app must surface this instead of replacing the catalog, so a transient
/// read failure can never destroy a user's identities.
class IdentityIndexException implements Exception {
  const IdentityIndexException(this.message);

  final String message;

  @override
  String toString() => 'IdentityIndexException($message)';
}

final RegExp _idPattern = RegExp(r'^[0-9a-f]{32}$');

/// Non-secret metadata for one virtual companion identity.
///
/// The private key lives only in secure storage, keyed by [id]. [publicKey] and
/// [name] are caches for display and duplicate checks; the node state and the
/// secure key remain the sources of truth.
class IdentityRecord {
  IdentityRecord({
    required this.id,
    required Uint8List publicKey,
    required this.name,
    required this.createdAt,
    this.enabled = true,
  }) : publicKey = Uint8List.fromList(publicKey);

  final String id;
  final Uint8List publicKey;
  final String name;
  final int createdAt;

  /// Whether this identity runs while a device is connected.
  ///
  /// Disabled identities keep their key, state, and queue but do not start a
  /// node, so they cannot receive, queue, or auto-add contacts.
  final bool enabled;

  IdentityRecord copyWith({
    Uint8List? publicKey,
    String? name,
    bool? enabled,
  }) =>
      IdentityRecord(
        id: id,
        publicKey: publicKey ?? this.publicKey,
        name: name ?? this.name,
        createdAt: createdAt,
        enabled: enabled ?? this.enabled,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'public_key': bytesToHex(publicKey),
        'name': name,
        'created_at': createdAt,
        'enabled': enabled,
      };

  static IdentityRecord? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final keyHex = json['public_key'];
    final name = json['name'];
    final createdAt = json['created_at'];
    final enabled = json['enabled'];
    if (id is! String || !_idPattern.hasMatch(id)) return null;
    if (keyHex is! String || name is! String || createdAt is! num) return null;
    if (enabled != null && enabled is! bool) return null;
    try {
      final key = hexToBytes(keyHex);
      if (key.length != pubKeySize) return null;
      return IdentityRecord(
        id: id,
        publicKey: key,
        name: name,
        createdAt: createdAt.toInt(),
        enabled: enabled as bool? ?? true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Persisted catalog of identities and the single active selection.
class IdentityIndex {
  IdentityIndex({
    this.version = identityIndexVersion,
    this.activeId,
    List<IdentityRecord>? identities,
  }) : identities = List<IdentityRecord>.of(identities ?? const []);

  final int version;
  final String? activeId;
  final List<IdentityRecord> identities;

  IdentityRecord? get activeRecord {
    final id = activeId;
    if (id == null) return null;
    for (final record in identities) {
      if (record.id == id) return record;
    }
    return null;
  }

  IdentityIndex copyWith({
    String? activeId,
    List<IdentityRecord>? identities,
  }) =>
      IdentityIndex(
        version: version,
        activeId: activeId ?? this.activeId,
        identities: identities ?? this.identities,
      );

  /// Whether this catalog was read from an older schema version.
  bool get needsMigration => version != identityIndexVersion;

  /// Rewrite a loaded catalog at the current schema version.
  IdentityIndex upgraded() => IdentityIndex(
        activeId: activeId,
        identities: identities,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'active_id': activeId,
        'identities': identities.map((record) => record.toJson()).toList(),
      };

  static IdentityIndex fromJson(Map<String, Object?> json) {
    final version = json['version'];
    if (version is! num ||
        version.toInt() < 1 ||
        version.toInt() > identityIndexVersion) {
      throw const IdentityIndexException('unsupported identity index version');
    }
    final rawIdentities = json['identities'];
    if (rawIdentities is! List) {
      throw const IdentityIndexException('identity list is missing');
    }
    final records = <IdentityRecord>[];
    final seenIds = <String>{};
    final seenKeys = <String>{};
    for (final raw in rawIdentities) {
      if (raw is! Map) {
        throw const IdentityIndexException('invalid identity record');
      }
      final record = IdentityRecord.fromJson(raw.cast<String, Object?>());
      if (record == null) {
        throw const IdentityIndexException('invalid identity record');
      }
      if (!seenIds.add(record.id)) {
        throw const IdentityIndexException('duplicate identity id');
      }
      if (!seenKeys.add(bytesToHex(record.publicKey))) {
        throw const IdentityIndexException('duplicate identity key');
      }
      records.add(record);
    }
    final activeId = json['active_id'];
    if (activeId != null && activeId is! String) {
      throw const IdentityIndexException('invalid active identity id');
    }
    return IdentityIndex(
      version: version.toInt(),
      activeId: activeId as String?,
      identities: records,
    );
  }
}

/// Atomic JSON persistence for [IdentityIndex].
///
/// Each successful save rotates the previous file to `.bak`. A corrupt primary
/// is read from that backup; if both copies are unusable the store throws so the
/// app can present a blocking recovery state rather than silently starting
/// over.
class IdentityIndexStore {
  IdentityIndexStore({required this.file});

  final File file;

  File get _backupFile => File('${file.path}.bak');
  File get _tempFile => File('${file.path}.tmp');
  Future<void> _tail = Future<void>.value();

  Future<IdentityIndex?> load() async {
    final primary = await _read(file);
    if (primary != null) return primary;
    if (await _backupFile.exists()) {
      final backup = await _read(_backupFile);
      if (backup != null) return backup;
    }
    if (await file.exists() || await _backupFile.exists()) {
      throw const IdentityIndexException(
        'identity database is unreadable; restore or clear app data',
      );
    }
    return null;
  }

  Future<IdentityIndex?> _read(File source) async {
    try {
      if (!await source.exists()) return null;
      final raw = await source.readAsString();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return IdentityIndex.fromJson(decoded.cast<String, Object?>());
    } on IdentityIndexException {
      rethrow;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> save(IdentityIndex index) {
    // Serialise writes so two catalog mutations can never share the temp file.
    final write = _tail.then(
      (_) => _write(index),
      onError: (Object _) => _write(index),
    );
    _tail = write.then((_) {}, onError: (Object _) {});
    return write;
  }

  Future<void> _write(IdentityIndex index) async {
    await file.parent.create(recursive: true);
    final encoded = jsonEncode(index.toJson());
    await _tempFile.writeAsString(encoded, flush: true);
    // Rotate only a readable catalog into the backup slot. A corrupt primary
    // must never overwrite the last good recovery copy.
    var primaryReadable = false;
    try {
      primaryReadable = await _read(file) != null;
    } on IdentityIndexException {
      primaryReadable = false;
    }
    if (primaryReadable) {
      try {
        await file.copy(_backupFile.path);
      } catch (_) {
        // A backup failure must not prevent the authoritative save. The next
        // successful save retries it.
      }
    }
    await _tempFile.rename(file.path);
  }

  /// New stable 16-byte hex identity id, avoiding [taken].
  static String newId({Set<String> taken = const {}}) {
    final random = Random.secure();
    while (true) {
      final bytes = Uint8List.fromList(
        List<int>.generate(16, (_) => random.nextInt(256)),
      );
      final id = bytesToHex(bytes);
      if (!taken.contains(id)) return id;
    }
  }
}

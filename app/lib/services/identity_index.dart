import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

/// Current on-disk identity index schema.
const int identityIndexVersion = 1;

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
  }) : publicKey = Uint8List.fromList(publicKey);

  final String id;
  final Uint8List publicKey;
  final String name;
  final int createdAt;

  IdentityRecord copyWith({
    Uint8List? publicKey,
    String? name,
  }) =>
      IdentityRecord(
        id: id,
        publicKey: publicKey ?? this.publicKey,
        name: name ?? this.name,
        createdAt: createdAt,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'public_key': bytesToHex(publicKey),
        'name': name,
        'created_at': createdAt,
      };

  static IdentityRecord? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final keyHex = json['public_key'];
    final name = json['name'];
    final createdAt = json['created_at'];
    if (id is! String || id.isEmpty) return null;
    if (keyHex is! String || name is! String || createdAt is! num) return null;
    try {
      final key = hexToBytes(keyHex);
      if (key.length != pubKeySize) return null;
      return IdentityRecord(
        id: id,
        publicKey: key,
        name: name,
        createdAt: createdAt.toInt(),
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
    bool clearActive = false,
    List<IdentityRecord>? identities,
  }) =>
      IdentityIndex(
        version: version,
        activeId: clearActive ? null : (activeId ?? this.activeId),
        identities: identities ?? this.identities,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'active_id': activeId,
        'identities': identities.map((record) => record.toJson()).toList(),
      };

  static IdentityIndex fromJson(Map<String, Object?> json) {
    final version = json['version'];
    if (version is! num || version.toInt() != identityIndexVersion) {
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

  Future<void> save(IdentityIndex index) async {
    await file.parent.create(recursive: true);
    final encoded = jsonEncode(index.toJson());
    await _tempFile.writeAsString(encoded, flush: true);
    if (await file.exists()) {
      try {
        await file.copy(_backupFile.path);
      } catch (_) {
        // A backup failure must not prevent the authoritative save. The next
        // successful save retries it.
      }
    }
    await _tempFile.rename(file.path);
  }

  /// Create a fresh index. The caller has already verified that no catalog
  /// exists; this helper exists so first-run creation can be retried.
  Future<void> saveFirst(IdentityIndex index) => save(index);

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

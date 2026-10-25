import 'dart:io';
import 'dart:typed_data';

import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'identity_index.dart';
import 'identity_store.dart';

/// Default name for the automatically created first identity.
const String defaultIdentityName = 'MeshChameleon';

/// Builds the per-identity node-state store for [file].
typedef NodeStoreFactory = NodeStore Function(File file);

/// Thrown when a requested identity name is not a valid advert name.
class IdentityNameException implements Exception {
  const IdentityNameException(this.message);

  final String message;

  @override
  String toString() => 'IdentityNameException($message)';
}

/// Thrown when a deletion would violate the active/last-identity rules.
class IdentityDeleteException implements Exception {
  const IdentityDeleteException(this.message);

  final String message;

  @override
  String toString() => 'IdentityDeleteException($message)';
}

/// Owns the identity catalog, secure key slots, and per-identity state paths.
///
/// All secrets stay behind [IdentityStore]. This class only ever exposes public
/// keys and non-secret metadata.
class IdentityRepository {
  IdentityRepository({
    required this.supportDirectory,
    required IdentityStore secureStore,
    NodeStoreFactory? nodeStoreFactory,
    this.onLog,
  })  : _secureStore = secureStore,
        _nodeStoreFactory =
            nodeStoreFactory ?? ((file) => JsonNodeStore(file: file));

  final Directory supportDirectory;
  final IdentityStore _secureStore;
  final NodeStoreFactory _nodeStoreFactory;
  final void Function(String message)? onLog;

  Directory get identitiesDirectory =>
      Directory('${supportDirectory.path}/identities');

  IdentityIndexStore get indexStore =>
      IdentityIndexStore(file: File('${identitiesDirectory.path}/index.json'));

  File stateFile(String id) =>
      File('${identitiesDirectory.path}/$id/node_state.json');

  NodeStore openNodeStore(String id) => _nodeStoreFactory(stateFile(id));

  /// Load the catalog, auto-creating and activating the first identity on a
  /// fresh install. A corrupt catalog throws [IdentityIndexException].
  Future<IdentityIndex> loadOrCreate() async {
    var index = await indexStore.load();
    if (index == null) {
      return _createFirst();
    }
    if (index.identities.isEmpty) {
      return _createFirst(existing: index);
    }
    final repaired = await _repairActive(index);
    return repaired;
  }

  Future<IdentityIndex> _createFirst({IdentityIndex? existing}) async {
    final created = await _create(
      defaultIdentityName,
      existing: existing ?? IdentityIndex(),
      activate: true,
    );
    return created.index;
  }

  Future<IdentityIndex> _repairActive(IdentityIndex index) async {
    final active = index.activeRecord;
    if (active != null) return index;
    // Prefer the first record whose key is actually readable; if none is, keep
    // the first record so the UI can show a recoverable "key unavailable"
    // state instead of dropping the catalog.
    IdentityRecord? chosen;
    for (final record in index.identities) {
      if (await _secureStore.loadById(record.id) != null) {
        chosen = record;
        break;
      }
    }
    chosen ??= index.identities.first;
    final repaired = index.copyWith(activeId: chosen.id);
    await indexStore.save(repaired);
    onLog?.call('Repaired active identity selection');
    return repaired;
  }

  Future<List<IdentityRecord>> records() async {
    final index = await loadOrCreate();
    return List<IdentityRecord>.of(index.identities);
  }

  Future<LocalIdentity?> loadKey(String id) => _secureStore.loadById(id);

  Future<bool> hasKey(String id) => _secureStore.hasById(id);

  /// Scoped persistence adapter used by the running node.
  VirtualIdentityPersistence persistenceFor(
    String id, {
    Future<void> Function(LocalIdentity identity)? validate,
  }) =>
      _secureStore.persistenceFor(id, validate: validate);

  /// Read the persisted state without creating it, quarantining a corrupt file
  /// so the next [openNodeStore] load starts fresh.
  Future<NodeState?> loadState(String id) async {
    final store = openNodeStore(id);
    final state = await store.load();
    if (state != null) return state;
    final file = stateFile(id);
    if (store is JsonNodeStore && await file.exists()) {
      final length = await file.length();
      if (length > 0) {
        final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
        try {
          await file.rename('${file.path}.corrupt-$stamp');
          onLog?.call('Quarantined corrupt identity state for $id');
        } catch (e) {
          onLog?.call('Could not quarantine corrupt identity state: $e');
        }
      }
    }
    return null;
  }

  Future<void> saveState(String id, NodeState state) =>
      openNodeStore(id).save(state);

  /// Create an additional identity. It is persisted but not activated.
  Future<IdentityRecord> create({String? name}) async {
    final selected = (name == null || name.trim().isEmpty)
        ? await suggestName()
        : name.trim();
    final valid = validateAdvertName(selected);
    if (valid == null) {
      throw const IdentityNameException('invalid identity name');
    }
    final index = await loadOrCreate();
    final result = await _create(valid, existing: index, activate: false);
    return result.record;
  }

  Future<({IdentityIndex index, IdentityRecord record})> _create(
    String name, {
    required IdentityIndex existing,
    required bool activate,
  }) async {
    final identity = await LocalIdentity.generate();
    if (!await LocalIdentity.validateMeshcore64(identity.meshcore64)) {
      throw StateError('generated identity failed validation');
    }
    final takenIds = {for (final record in existing.identities) record.id};
    final id = IdentityIndexStore.newId(taken: takenIds);
    await _ensureUniqueKey(existing, identity.publicKey);
    final record = IdentityRecord(
      id: id,
      publicKey: identity.publicKey,
      name: name,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );

    var wroteKey = false;
    try {
      await _secureStore.saveById(id, identity);
      wroteKey = true;
      await openNodeStore(id).save(defaultNodeState(name));
      final records = [...existing.identities, record];
      final next = IdentityIndex(
        activeId: activate ? id : existing.activeId,
        identities: records,
      );
      await indexStore.save(next);
      return (index: next, record: record);
    } catch (e) {
      if (wroteKey) {
        try {
          await _secureStore.deleteById(id);
        } catch (_) {}
      }
      try {
        final dir = Directory('${identitiesDirectory.path}/$id');
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _ensureUniqueKey(
    IdentityIndex index,
    Uint8List publicKey, {
    String? exceptId,
  }) async {
    final hex = bytesToHex(publicKey);
    for (final record in index.identities) {
      if (record.id == exceptId) continue;
      if (bytesToHex(record.publicKey) == hex) {
        throw const IdentityNameException(
          'that identity key is already in use by another identity',
        );
      }
    }
  }

  /// The first unused name in `MeshChameleon`, `MeshChameleon 2`, ...
  Future<String> suggestName() async {
    final index = await indexStore.load();
    final used = {
      for (final record in index?.identities ?? const <IdentityRecord>[])
        record.name.toLowerCase(),
    };
    if (!used.contains(defaultIdentityName.toLowerCase())) {
      return defaultIdentityName;
    }
    for (var i = 2;; i++) {
      final candidate = '$defaultIdentityName $i';
      if (!used.contains(candidate.toLowerCase())) return candidate;
    }
  }

  /// Delete an identity. Only inactive records may be removed and at least one
  /// record must remain. The catalog update is the user-visible delete; key and
  /// state cleanup failures are logged because the record is already gone.
  Future<void> delete(String id) async {
    final index = await loadOrCreate();
    IdentityRecord? record;
    for (final item in index.identities) {
      if (item.id == id) {
        record = item;
        break;
      }
    }
    if (record == null) throw const IdentityDeleteException('identity not found');
    if (index.activeId == id) {
      throw const IdentityDeleteException(
        'activate another identity before deleting this one',
      );
    }
    if (index.identities.length <= 1) {
      throw const IdentityDeleteException(
        'at least one identity must remain',
      );
    }
    final remaining = [
      for (final item in index.identities)
        if (item.id != id) item,
    ];
    await indexStore.save(index.copyWith(identities: remaining));
    try {
      await _secureStore.deleteById(id);
    } catch (e) {
      onLog?.call('Could not delete identity key for $id: $e');
    }
    try {
      final dir = Directory('${identitiesDirectory.path}/$id');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      onLog?.call('Could not delete identity state for $id: $e');
    }
  }

  Future<IdentityRecord> updateName(String id, String name) async {
    final valid = validateAdvertName(name);
    if (valid == null) {
      throw const IdentityNameException('invalid identity name');
    }
    return _updateRecord(id, (record) => record.copyWith(name: valid));
  }

  Future<IdentityRecord> updatePublicKey(
    String id,
    Uint8List publicKey, {
    String? attachedDeviceKeyHex,
  }) async {
    if (publicKey.length != pubKeySize) {
      throw const IdentityNameException('invalid identity public key');
    }
    final index = await loadOrCreate();
    await _ensureUniqueKey(index, publicKey, exceptId: id);
    if (attachedDeviceKeyHex != null &&
        bytesToHex(publicKey) == attachedDeviceKeyHex) {
      throw const IdentityNameException(
        'the attached companion identity cannot be used as a virtual identity',
      );
    }
    return _updateRecord(
      id,
      (record) => record.copyWith(publicKey: publicKey),
      existing: index,
    );
  }

  Future<IdentityRecord> _updateRecord(
    String id,
    IdentityRecord Function(IdentityRecord record) update, {
    IdentityIndex? existing,
  }) async {
    final index = existing ?? await loadOrCreate();
    final records = <IdentityRecord>[];
    IdentityRecord? updated;
    for (final record in index.identities) {
      if (record.id == id) {
        updated = update(record);
        records.add(updated);
      } else {
        records.add(record);
      }
    }
    if (updated == null) {
      throw const IdentityNameException('identity not found');
    }
    await indexStore.save(index.copyWith(identities: records));
    return updated;
  }

  Future<void> setActive(String id) async {
    final index = await loadOrCreate();
    if (!index.identities.any((record) => record.id == id)) {
      throw const IdentityDeleteException('identity not found');
    }
    if (index.activeId == id) return;
    await indexStore.save(index.copyWith(activeId: id));
  }

  /// Clear everything virtual except the identity key and current name.
  Future<void> clearLocalData(String id) async {
    final index = await loadOrCreate();
    IdentityRecord? record;
    for (final item in index.identities) {
      if (item.id == id) {
        record = item;
        break;
      }
    }
    if (record == null) {
      throw const IdentityDeleteException('identity not found');
    }
    final state = await loadState(id);
    final name = state?.prefs.nodeName ?? record.name;
    final fresh = defaultNodeState(name);
    await saveState(id, fresh);
  }

  /// Remove per-identity state directories that no catalog record references.
  ///
  /// Secure key slots are deliberately never removed here. On Linux,
  /// `flutter_secure_storage` keeps every key in one slot keyed by application
  /// id, so a catalog from one support directory must not be allowed to prune
  /// another catalog's keys.
  Future<void> cleanupOrphans() async {
    final index = await indexStore.load();
    if (index == null) return;
    final known = {for (final record in index.identities) record.id};
    final dir = identitiesDirectory;
    try {
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          if (entity is! Directory) continue;
          final name = entity.path.split(Platform.pathSeparator).last;
          if (known.contains(name)) continue;
          try {
            await entity.delete(recursive: true);
            onLog?.call('Removed orphaned identity state directory');
          } catch (e) {
            onLog?.call('Could not remove orphaned identity state: $e');
          }
        }
      }
    } on FileSystemException catch (e) {
      onLog?.call('Could not scan identity state directories: $e');
    }
  }
}

/// S2-default node state for a new or cleared identity.
NodeState defaultNodeState(String name) {
  final state = freshVirtualState();
  state.prefs.nodeName = name;
  return state;
}

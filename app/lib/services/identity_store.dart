import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

/// Stores each virtual identity (64-byte expanded key) in Android
/// Keystore-backed secure storage.
///
/// On Android the values use AES-256-GCM data encryption with an RSA-OAEP key
/// wrapping key held in the hardware-backed Android Keystore. Keys are never
/// written to plaintext storage, logs, or the app UI.
///
/// The pre-multi-identity `meshcore_identity_v1` entry is deliberately ignored;
/// this store only addresses the per-record `meshcore_identity_v2/<id>` slots.
class IdentityStore {
  IdentityStore({FlutterSecureStorage? storage})
      : _storage = storage ?? _defaultStorage();

  /// v10 migrates v9 `EncryptedSharedPreferences` entries on first access.
  /// Keep migration backups enabled and never auto-reset on a storage error:
  /// an unreadable key must surface as unavailable, not erase the catalog.
  static FlutterSecureStorage _defaultStorage() => const FlutterSecureStorage(
        aOptions: AndroidOptions(
          resetOnError: false,
          migrateWithBackup: true,
        ),
      );

  static const _prefix = 'meshcore_identity_v2/';
  final FlutterSecureStorage _storage;

  static String _storageKey(String id) => '$_prefix$id';

  Future<LocalIdentity?> loadById(String id) async {
    final hex = await _storage.read(key: _storageKey(id));
    if (hex == null || hex.isEmpty) return null;
    try {
      final bytes = hexToBytes(hex);
      if (bytes.length != 64 ||
          !await LocalIdentity.validateMeshcore64(bytes)) {
        return null;
      }
      return await LocalIdentity.import(bytes);
    } catch (_) {
      return null;
    }
  }

  /// Whether a non-empty key slot exists, without validating the key material.
  ///
  /// Storage errors are reported as "unavailable" so one unreadable slot
  /// cannot block loading the rest of the catalog.
  Future<bool> hasById(String id) async {
    try {
      final value = await _storage.read(key: _storageKey(id));
      return value != null && value.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> saveById(String id, LocalIdentity identity) => _storage.write(
        key: _storageKey(id),
        value: bytesToHex(identity.meshcore64),
      );

  Future<void> deleteById(String id) => _storage.delete(key: _storageKey(id));

  /// A [VirtualIdentityPersistence] scoped to one identity record.
  ///
  /// [validate] runs before the durable write so protocol key imports can
  /// reject a duplicate or attached-radio key without changing storage.
  VirtualIdentityPersistence persistenceFor(
    String id, {
    Future<void> Function(LocalIdentity identity)? validate,
  }) =>
      _RecordPersistence(this, id, validate);
}

class _RecordPersistence implements VirtualIdentityPersistence {
  _RecordPersistence(this._store, this._id, this._validate);

  final IdentityStore _store;
  final String _id;
  final Future<void> Function(LocalIdentity identity)? _validate;

  @override
  Future<LocalIdentity?> load() => _store.loadById(_id);

  @override
  Future<void> save(LocalIdentity identity) async {
    await _validate?.call(identity);
    await _store.saveById(_id, identity);
  }
}

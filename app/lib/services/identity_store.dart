import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

/// Stores each virtual identity (64-byte expanded key) in Android
/// Keystore-backed secure storage.
///
/// On Android the values live in Jetpack Security `EncryptedSharedPreferences`
/// (AES-256-GCM, with the master key held in the hardware-backed Android
/// Keystore). Keys are never written to plaintext storage, logs, or the app UI.
///
/// The pre-multi-identity `meshcore_identity_v1` entry is deliberately ignored;
/// this store only addresses the per-record `meshcore_identity_v2/<id>` slots.
class IdentityStore {
  IdentityStore({FlutterSecureStorage? storage})
      : _storage = storage ?? _defaultStorage();

  /// `EncryptedSharedPreferences` requires API 23+; the app's `minSdk` is 24.
  /// Prefer it over the legacy RSA/AES-CBC backend, which the plugin still
  /// defaults to.
  static FlutterSecureStorage _defaultStorage() => const FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
      );

  static const _prefix = 'meshcore_identity_v2/';
  final FlutterSecureStorage _storage;

  static String storageKey(String id) => '$_prefix$id';

  Future<LocalIdentity?> loadById(String id) async {
    final hex = await _storage.read(key: storageKey(id));
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
  Future<bool> hasById(String id) async {
    final value = await _storage.read(key: storageKey(id));
    return value != null && value.isNotEmpty;
  }

  Future<void> saveById(String id, LocalIdentity identity) =>
      _storage.write(
        key: storageKey(id),
        value: bytesToHex(identity.meshcore64),
      );

  Future<void> deleteById(String id) => _storage.delete(key: storageKey(id));

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

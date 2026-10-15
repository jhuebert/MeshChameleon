import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

/// Stores the MeshCore identity (64-byte expanded key) in Android
/// Keystore-backed secure storage.
///
/// On Android the value is kept in Jetpack Security `EncryptedSharedPreferences`
/// (AES-256-GCM, with the master key held in the hardware-backed Android
/// Keystore). The 64-byte identity is never written to plaintext storage, logs,
/// or the app UI unless the user explicitly reveals it (see [exportKey]).
class IdentityStore {
  IdentityStore({FlutterSecureStorage? storage})
      : _storage = storage ?? _defaultStorage();

  /// `EncryptedSharedPreferences` requires API 23+; the app's `minSdk` is 24.
  /// Prefer it over the legacy RSA/AES-CBC backend, which the plugin still
  /// defaults to.
  static FlutterSecureStorage _defaultStorage() => const FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
      );

  static const _key = 'meshcore_identity_v1';
  final FlutterSecureStorage _storage;

  Future<LocalIdentity?> load() async {
    final hex = await _storage.read(key: _key);
    if (hex == null || hex.isEmpty) return null;
    try {
      return await LocalIdentity.import(hexToBytes(hex));
    } catch (_) {
      return null;
    }
  }

  Future<LocalIdentity> generate() async {
    final identity = await LocalIdentity.generate();
    await save(identity);
    return identity;
  }

  Future<LocalIdentity> import(Uint8List key) async {
    final identity = await LocalIdentity.import(key);
    await save(identity);
    return identity;
  }

  Future<void> save(LocalIdentity identity) =>
      _storage.write(key: _key, value: bytesToHex(identity.meshcore64));

  /// The exportable 64-byte MeshCore key form. Never log this.
  Future<Uint8List?> exportKey() async {
    final identity = await load();
    return identity?.meshcore64;
  }

  Future<void> clear() => _storage.delete(key: _key);
}

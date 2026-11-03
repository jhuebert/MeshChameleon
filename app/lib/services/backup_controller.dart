import 'dart:typed_data';

import 'backup_codec.dart';
import 'backup_service.dart';
import 'identity_repository.dart';
import 'identity_store.dart';
import 'network_connection_store.dart';
import 'session_store.dart';

/// Creates the encrypted backup service and wraps its capture/inspect/restore
/// calls with the app version.
///
/// Restore ordering (disconnect, dispose the live manager, reload identities)
/// stays with the app owner because it coordinates the connection and identity
/// layers; this class only owns the backup service instance.
class BackupController {
  BackupController({
    required this.repository,
    required this.identityStore,
    required this.sessionStore,
    required this.networkConnectionStore,
    required this.appVersion,
    required this.log,
  });

  final Future<IdentityRepository> Function() repository;
  final IdentityStore identityStore;
  final SessionStore sessionStore;
  final NetworkConnectionStore networkConnectionStore;
  final String Function() appVersion;
  final void Function(String message) log;

  BackupService? _service;

  Future<BackupService> ensureService() async {
    final existing = _service;
    if (existing != null) return existing;
    final created = BackupService(
      repository: await repository(),
      identityStore: identityStore,
      sessionStore: sessionStore,
      networkConnectionStore: networkConnectionStore,
      onLog: log,
    );
    _service = created;
    return created;
  }

  /// Roll back a restore that was interrupted by a process death.
  Future<void> recoverInterruptedRestore() async {
    final service = await ensureService();
    await service.recoverInterruptedRestore();
  }

  /// Capture all local data into a passphrase-encrypted backup file.
  Future<Uint8List> create(String passphrase) async {
    final service = await ensureService();
    final payload = await service.capture();
    return BackupCodec.seal(
      payload: payload,
      passphrase: passphrase,
      appVersion: appVersion(),
    );
  }

  /// Decrypt and validate a backup without changing local data.
  Future<BackupPreview> inspect(Uint8List bytes, String passphrase) async {
    final service = await ensureService();
    return service.inspect(bytes: bytes, passphrase: passphrase);
  }

  /// Replace all local data with a validated backup.
  Future<void> restore(BackupPreview preview) async {
    final service = await ensureService();
    await service.restore(preview);
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/services/backup_codec.dart';
import 'package:meshchameleon/services/backup_service.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/network_connection_store.dart';
import 'package:meshchameleon/services/session_store.dart';

void main() {
  _extraBackupServiceTests();

  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late IdentityStore store;
  late IdentityRepository repository;
  late SessionStore sessions;
  late NetworkConnectionStore networks;
  late BackupService service;
  const passphrase = 'backup passphrase';

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mesh_backup_service_');
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    store = IdentityStore();
    repository = IdentityRepository(supportDirectory: dir, secureStore: store);
    sessions = SessionStore(file: File('${dir.path}/session.json'));
    networks = NetworkConnectionStore(
      file: File('${dir.path}/network_connections.json'),
    );
    service = BackupService(
      repository: repository,
      identityStore: store,
      sessionStore: sessions,
      networkConnectionStore: networks,
    );
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  Future<Uint8List> makeBackup() async {
    final payload = await service.capture();
    return BackupCodec.seal(
      payload: payload,
      passphrase: passphrase,
      appVersion: '0.1.0',
    );
  }

  test('round-trips identities, state, session, and saved connections',
      () async {
    final index = await repository.loadOrCreate();
    final record = index.activeRecord!;
    final state = (await repository.loadState(record.id))!;
    state.prefs.nodeName = 'Backup Name';
    await repository.saveState(record.id, state);
    await sessions.save(const SessionConfig(
      kind: DeviceTargetKind.tcp,
      host: '10.0.0.2',
      devicePort: 5000,
      proxyPort: 5100,
      autoResume: true,
    ));
    await networks.save([
      const SavedNetworkConnection(
        host: '10.0.0.9',
        port: 5000,
        lastConnectedAt: 1000,
      ),
    ]);

    final bytes = await makeBackup();
    final preview = await service.inspect(bytes: bytes, passphrase: passphrase);
    expect(preview.identityCount, 1);
    expect(preview.contactCount, 0);

    final originalKey = await store.loadById(record.id);
    await store.saveById(record.id, await LocalIdentity.generate());
    state.prefs.nodeName = 'Changed';
    await repository.saveState(record.id, state);
    await sessions.save(const SessionConfig(
      kind: DeviceTargetKind.tcp,
      host: 'changed.example',
      proxyPort: 5555,
    ));
    await networks.delete();

    await service.restore(preview);

    final restoredState = (await repository.loadState(record.id))!;
    expect(restoredState.prefs.nodeName, 'Backup Name');
    final restoredKey = await store.loadById(record.id);
    expect(bytesToHex(restoredKey!.meshcore64),
        bytesToHex(originalKey!.meshcore64));
    final restoredSession = await sessions.load();
    expect(restoredSession!.host, '10.0.0.2');
    expect(restoredSession.proxyPort, 5100);
    expect(restoredSession.autoResume, isTrue);
    final restoredNetworks = await networks.load();
    expect(restoredNetworks.single.host, '10.0.0.9');
    expect(await repository.loadKey(record.id), isNotNull);

    final names = dir
        .listSync()
        .map((entity) => entity.path.split(Platform.pathSeparator).last);
    expect(
      names.any((name) => name.startsWith('identities.recovery-')),
      isTrue,
    );
  });

  test('an interrupted restore rolls back catalog and keys at startup',
      () async {
    final index = await repository.loadOrCreate();
    final record = index.activeRecord!;
    final oldKey = (await store.loadById(record.id))!;
    const stamp = '2026-01-02T03-04-05-000Z';
    final current = repository.identitiesDirectory;
    final recovery = Directory('${dir.path}/identities.recovery-$stamp');
    await current.rename(recovery.path);

    // Simulate the partially installed catalog left by a crash.
    await current.create(recursive: true);
    await File('${current.path}/index.json').writeAsString('{}');

    await store.saveRestoreBackup(record.id, oldKey);
    await File('${dir.path}/restore-in-progress.json').writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'complete': false,
        'stamp': stamp,
        'had_current': true,
        'old_ids': [record.id],
        'old_key_ids': [record.id],
      }),
    );

    await service.recoverInterruptedRestore();

    final restored = await repository.loadOrCreate();
    expect(restored.activeId, record.id);
    expect(
      bytesToHex((await store.loadById(record.id))!.meshcore64),
      bytesToHex(oldKey.meshcore64),
    );
    expect(
        await File('${dir.path}/restore-in-progress.json').exists(), isFalse);
    expect(await recovery.exists(), isFalse);
    expect(await store.loadRestoreBackup(record.id), isNull);
  });

  test('a completed restore marker only cleans up rollback snapshots',
      () async {
    final index = await repository.loadOrCreate();
    final record = index.activeRecord!;
    final oldKey = (await store.loadById(record.id))!;
    final indexFile = File('${dir.path}/identities/index.json');
    final before = await indexFile.readAsString();
    await store.saveRestoreBackup(record.id, oldKey);
    await File('${dir.path}/restore-in-progress.json').writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'complete': true,
        'stamp': '2026-01-02T03-04-05-000Z',
        'had_current': true,
        'old_ids': [record.id],
        'old_key_ids': [record.id],
      }),
    );

    await service.recoverInterruptedRestore();

    expect(await indexFile.readAsString(), before);
    expect(
        await File('${dir.path}/restore-in-progress.json').exists(), isFalse);
    expect(await store.loadRestoreBackup(record.id), isNull);
  });

  test('restore removes keys for identities that are not in the backup',
      () async {
    await repository.loadOrCreate();
    final preview = await service.inspect(
      bytes: await makeBackup(),
      passphrase: passphrase,
    );

    final added = await repository.create(name: 'After Backup');
    expect(await store.hasById(added.id), isTrue);

    await service.restore(preview);

    final restoredCatalog = await repository.loadOrCreate();
    expect(restoredCatalog.identities, hasLength(1));
    expect(restoredCatalog.identities.single.id, isNot(added.id));
    expect(await store.hasById(added.id), isFalse,
        reason: 'restore must replace the whole key store');
  });

  test('capture fails when an identity key is missing', () async {
    final index = await repository.loadOrCreate();
    await store.deleteById(index.activeRecord!.id);

    await expectLater(service.capture(), throwsA(isA<BackupException>()));
  });

  test('capture rejects a key that no longer matches the catalog', () async {
    final index = await repository.loadOrCreate();
    final record = index.activeRecord!;
    await store.saveById(record.id, await LocalIdentity.generate());

    await expectLater(service.capture(), throwsA(isA<BackupException>()));
  });

  test('capture fails when an identity state is unreadable', () async {
    final index = await repository.loadOrCreate();
    await repository
        .stateFile(index.activeRecord!.id)
        .writeAsString('{not json');

    await expectLater(service.capture(), throwsA(isA<BackupException>()));
  });

  test('inspect rejects a key that does not match the catalog', () async {
    final index = await repository.loadOrCreate();
    final record = index.activeRecord!;
    final other = await repository.create(name: 'Second');
    final bytes = await makeBackup();

    final opened = await BackupCodec.open(
      bytes: bytes,
      passphrase: passphrase,
    );
    final identities = (opened['identities']! as Map).cast<String, Object?>();
    final entry = (identities[record.id]! as Map).cast<String, Object?>();
    entry['key'] = bytesToHex((await repository.loadKey(other.id))!.meshcore64);
    identities[record.id] = entry;
    opened['identities'] = identities;
    final tampered = await BackupCodec.seal(
      payload: opened,
      passphrase: passphrase,
      appVersion: '0.1.0',
    );

    await expectLater(
      service.inspect(bytes: tampered, passphrase: passphrase),
      throwsA(isA<BackupException>()),
    );
  });

  test('inspect upgrades an older catalog schema', () async {
    await repository.loadOrCreate();
    final bytes = await makeBackup();
    final opened = await BackupCodec.open(
      bytes: bytes,
      passphrase: passphrase,
    );
    final index = (opened['index']! as Map).cast<String, Object?>();
    index['version'] = 1;
    for (final raw in index['identities']! as List) {
      (raw as Map).remove('enabled');
    }
    opened['index'] = index;
    final older = await BackupCodec.seal(
      payload: opened,
      passphrase: passphrase,
      appVersion: '0.1.0',
    );

    final preview = await service.inspect(bytes: older, passphrase: passphrase);
    expect(preview.identityCount, 1);
  });

  test('inspect rejects duplicate identity keys', () async {
    await repository.loadOrCreate();
    final bytes = await makeBackup();
    final opened = await BackupCodec.open(
      bytes: bytes,
      passphrase: passphrase,
    );
    final indexJson = (opened['index']! as Map).cast<String, Object?>();
    final records =
        (indexJson['identities']! as List).cast<Map<Object?, Object?>>();
    final duplicate = Map<Object?, Object?>.from(records.single);
    duplicate['id'] = '0123456789abcdef0123456789abcdef';
    records.add(duplicate);
    indexJson['identities'] = records;
    opened['index'] = indexJson;
    final tampered = await BackupCodec.seal(
      payload: opened,
      passphrase: passphrase,
      appVersion: '0.1.0',
    );

    await expectLater(
      service.inspect(bytes: tampered, passphrase: passphrase),
      throwsA(isA<BackupException>()),
    );
  });

  test('inspect rejects a missing identity entry', () async {
    await repository.loadOrCreate();
    final bytes = await makeBackup();
    final opened = await BackupCodec.open(
      bytes: bytes,
      passphrase: passphrase,
    );
    opened['identities'] = <String, Object?>{};
    final tampered = await BackupCodec.seal(
      payload: opened,
      passphrase: passphrase,
      appVersion: '0.1.0',
    );

    await expectLater(
      service.inspect(bytes: tampered, passphrase: passphrase),
      throwsA(isA<BackupException>()),
    );
  });
}

// Additional restore/validation coverage.

class _FailingNetworkStore extends NetworkConnectionStore {
  _FailingNetworkStore({super.file});

  @override
  Future<void> save(List<SavedNetworkConnection> connections) async {
    throw StateError('network write failed');
  }
}

void _extraBackupServiceTests() {
  late Directory dir;
  late IdentityStore store;
  late IdentityRepository repository;
  late SessionStore sessions;
  late NetworkConnectionStore networks;
  late BackupService service;
  late List<String> logs;
  const passphrase = 'backup passphrase';

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mesh_backup_service_extra_');
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    store = IdentityStore();
    repository = IdentityRepository(supportDirectory: dir, secureStore: store);
    sessions = SessionStore(file: File('${dir.path}/session.json'));
    networks = NetworkConnectionStore(
      file: File('${dir.path}/network_connections.json'),
    );
    logs = [];
    service = BackupService(
      repository: repository,
      identityStore: store,
      sessionStore: sessions,
      networkConnectionStore: networks,
      onLog: logs.add,
    );
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  Future<Uint8List> makeBackup() async {
    final payload = await service.capture();
    return BackupCodec.seal(
      payload: payload,
      passphrase: passphrase,
      appVersion: '0.1.0',
    );
  }

  Future<Uint8List> tampered(
    void Function(Map<String, Object?> payload) mutate,
  ) async {
    final opened = await BackupCodec.open(
      bytes: await makeBackup(),
      passphrase: passphrase,
    );
    mutate(opened);
    return BackupCodec.seal(
      payload: opened,
      passphrase: passphrase,
      appVersion: '0.1.0',
    );
  }

  test('restore clears a session and saved connections that were absent',
      () async {
    await repository.loadOrCreate();
    final bytes = await tampered((payload) {
      payload['session'] = null;
      payload['network_connections'] = null;
    });
    final preview = await service.inspect(bytes: bytes, passphrase: passphrase);
    await sessions.save(const SessionConfig(
      kind: DeviceTargetKind.tcp,
      host: 'old.example',
      proxyPort: 5000,
    ));
    await networks.save([
      const SavedNetworkConnection(
        host: '10.0.0.9',
        port: 5000,
        lastConnectedAt: 1000,
      ),
    ]);

    await service.restore(preview);

    expect(await sessions.load(), isNull);
    expect(await networks.load(), isEmpty);
  });

  test('restore prunes older recovery copies', () async {
    await repository.loadOrCreate();
    final preview = await service.inspect(
      bytes: await makeBackup(),
      passphrase: passphrase,
    );
    final older = Directory('${dir.path}/identities.recovery-old')
      ..createSync(recursive: true);
    expect(older.existsSync(), isTrue);

    await service.restore(preview);

    expect(older.existsSync(), isFalse);
    expect(logs, anyElement(contains('Restored 1 identities')));
  });

  test('a failed settings write rolls back keys, session, and logs', () async {
    final index = await repository.loadOrCreate();
    final record = index.activeRecord!;
    final originalKey = await store.loadById(record.id);
    await sessions.save(const SessionConfig(
      kind: DeviceTargetKind.tcp,
      host: 'before.example',
      proxyPort: 5000,
    ));
    final preview = await service.inspect(
      bytes: await makeBackup(),
      passphrase: passphrase,
    );

    final failing = _FailingNetworkStore(
      file: File('${dir.path}/failing_networks.json'),
    );
    final failingService = BackupService(
      repository: repository,
      identityStore: store,
      sessionStore: sessions,
      networkConnectionStore: failing,
      onLog: logs.add,
    );

    await expectLater(failingService.restore(preview), throwsStateError);

    final restoredKey = await store.loadById(record.id);
    expect(bytesToHex(restoredKey!.meshcore64),
        bytesToHex(originalKey!.meshcore64));
    expect((await sessions.load())!.host, 'before.example');
    expect(logs, anyElement(contains('rolling back')));
  });

  test('inspect rejects malformed identity entries and state', () async {
    await repository.loadOrCreate();

    Future<void> rejects(
      void Function(Map<String, Object?> payload) mutate,
    ) async {
      await expectLater(
        service.inspect(bytes: await tampered(mutate), passphrase: passphrase),
        throwsA(isA<BackupException>()),
      );
    }

    await rejects((payload) {
      final identities =
          (payload['identities']! as Map).cast<String, Object?>();
      final id = identities.keys.single;
      identities[id] = 'not a map';
      payload['identities'] = identities;
    });

    await rejects((payload) {
      final identities =
          (payload['identities']! as Map).cast<String, Object?>();
      final id = identities.keys.single;
      (identities[id]! as Map).remove('key');
      payload['identities'] = identities;
    });

    await rejects((payload) {
      final identities =
          (payload['identities']! as Map).cast<String, Object?>();
      final id = identities.keys.single;
      (identities[id]! as Map)['key'] = '00';
      payload['identities'] = identities;
    });

    await rejects((payload) {
      final identities =
          (payload['identities']! as Map).cast<String, Object?>();
      final id = identities.keys.single;
      (identities[id]! as Map)['state'] = 'bad state';
      payload['identities'] = identities;
    });
  });

  test('inspect rejects malformed saved connections', () async {
    await repository.loadOrCreate();
    await expectLater(
      service.inspect(
        bytes: await tampered(
          (payload) => payload['network_connections'] = 'not connections',
        ),
        passphrase: passphrase,
      ),
      throwsA(isA<BackupException>()),
    );
  });
}

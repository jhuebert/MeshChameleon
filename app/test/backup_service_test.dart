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

  test('capture fails when an identity key is missing', () async {
    final index = await repository.loadOrCreate();
    await store.deleteById(index.activeRecord!.id);

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

import 'dart:io';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/services/identity_manager.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late IdentityRepository repository;
  late IdentityManager manager;
  late FakeDeviceLink link;
  late Map<String, String> values;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mesh_identity_manager_');
    values = <String, String>{};
    FlutterSecureStorage.setMockInitialValues(values);
    repository = IdentityRepository(
      supportDirectory: dir,
      secureStore: IdentityStore(),
    );
    manager = IdentityManager(
      repository: repository,
      notifyDebounce: const Duration(milliseconds: 1),
    );
    link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    await link.connect();
  });

  tearDown(() async {
    await manager.dispose();
    await link.disconnect();
    await dir.delete(recursive: true);
  });

  Future<LocalIdentity> keyFor(String id) async {
    final key = await repository.loadKey(id);
    expect(key, isNotNull);
    return key!;
  }

  Future<void> start() => manager.startLive(
        base: link,
        physical: const PhysicalCapabilities(firmwareVerCode: 14),
        radioParams: link.initialRadioParams,
      );

  test('load_auto_creates_one_active_summary', () async {
    await manager.load();
    expect(manager.databaseError, isNull);
    expect(manager.summaries, hasLength(1));
    final summary = manager.summaries.single;
    expect(summary.name, 'MeshChameleon');
    expect(summary.active, isTrue);
    expect(summary.live, isFalse);
    expect(summary.channelCount, 1);
    expect(summary.contactCount, 0);
    expect(summary.prefixHex, hasLength(8));
  });

  test('start_live_runs_every_identity_and_isolates_counts', () async {
    await manager.load();
    final first = manager.summaries.single.id;
    final second = await repository.create(name: 'Second');
    await repository.saveState(
      second.id,
      NodeState(
        prefs: NodePrefs(nodeName: 'Second'),
        queue: [QueuedMessage(senderKey: Uint8List(0), text: 'only second')],
        contacts: [
          Contact(
            publicKey: (await LocalIdentity.generate()).publicKey,
            name: 'Peer',
          ),
        ],
      ),
    );
    await manager.load();
    await start();

    expect(manager.runtimes, hasLength(2));
    expect(manager.summaries.every((s) => s.live), isTrue);
    final summaries = {for (final s in manager.summaries) s.id: s};
    expect(summaries[first]!.queuedDirect, 0);
    expect(summaries[first]!.contactCount, 0);
    expect(summaries[second.id]!.queuedDirect, 1);
    expect(summaries[second.id]!.contactCount, 1);
  });

  test('active_is_first_then_case_insensitive_name_order', () async {
    await manager.load();
    final first = manager.summaries.single.id;
    final beta = await repository.create(name: 'beta');
    final alpha = await repository.create(name: 'Alpha');
    await manager.load();
    await manager.activate(first);
    await start();

    expect(
      manager.summaries.map((s) => s.name).toList(),
      ['MeshChameleon', 'Alpha', 'beta'],
    );

    final active = manager.summaries.first;
    expect(active.id, first);
    expect(manager.summaries.map((s) => s.id),
        containsAll([alpha.id, beta.id]));
  });

  test('activation_switches_bridge_to_the_existing_live_node', () async {
    await manager.load();
    final second = await repository.create(name: 'Second');
    await start();
    MeshNode? bridged;

    final ok = await manager.activate(
      second.id,
      switchBridge: (node) async => bridged = node,
    );

    expect(ok, isTrue);
    expect(manager.activeId, second.id);
    expect(bridged, same(manager.activeNode));
    expect(manager.activeSummary!.name, 'Second');
    final persisted = await repository.loadOrCreate();
    expect(persisted.activeId, second.id);
  });

  test('protocol name change updates the cached record and summary', () async {
    await manager.load();
    final first = manager.summaries.single.id;
    await start();
    final node = manager.activeNode!;

    await node.setAdvertName('Renamed Virtually');
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(manager.activeSummary!.name, 'Renamed Virtually');
    final record = (await repository.records()).single;
    expect(record.id, first);
    expect(record.name, 'Renamed Virtually');
  });

  test('duplicate keys are detected and only one node stays live', () async {
    await manager.load();
    final first = manager.summaries.single.id;
    final second = await repository.create(name: 'Second');
    final firstKey = await keyFor(first);
    await IdentityStore().saveById(second.id, firstKey);
    await manager.load();
    await start();

    final summaries = {for (final s in manager.summaries) s.id: s};
    expect(summaries[first]!.live, isTrue);
    expect(summaries[second.id]!.live, isFalse);
    expect(summaries[second.id]!.unavailableReason, contains('Duplicate'));
  });

  test('missing key marks the identity unavailable', () async {
    await manager.load();
    final second = await repository.create(name: 'Second');
    await IdentityStore().deleteById(second.id);
    await manager.load();
    await start();

    final summary =
        manager.summaries.firstWhere((summary) => summary.id == second.id);
    expect(summary.live, isFalse);
    expect(summary.keyAvailable, isFalse);
    expect(summary.unavailableReason, isNotNull);
    expect(await manager.activate(second.id), isFalse);
  });

  test('attached radio key conflict keeps the runtime stopped', () async {
    await manager.load();
    final first = await keyFor(manager.summaries.single.id);
    await manager.startLive(
      base: link,
      physical: const PhysicalCapabilities(firmwareVerCode: 14),
      radioParams: link.initialRadioParams,
      devicePublicKey: first.publicKey,
    );

    final summary = manager.summaries.single;
    expect(summary.live, isFalse);
    expect(summary.unavailableReason, contains('attached companion'));
  });

  test('live DM is mirrored through the manager without RF echo', () async {
    await manager.load();
    final firstId = manager.summaries.single.id;
    final second = await repository.create(name: 'Second');
    await start();
    final a = manager.runtimes
        .firstWhere((runtime) => runtime.record.id == firstId)
        .node!;
    final b = manager.runtimes
        .firstWhere((runtime) => runtime.record.id == second.id)
        .node!;
    await a.addUpdateContact(Contact(
      publicKey: b.identity.publicKey,
      name: 'B',
      outPathLen: 0,
      outPath: Uint8List(0),
    ));
    await b.addUpdateContact(Contact(
      publicKey: a.identity.publicKey,
      name: 'A',
      outPathLen: 0,
      outPath: Uint8List(0),
    ));

    final sent = await a.sendTextMessage(b.identity.publicKey, 'local');
    await Future<void>.delayed(const Duration(milliseconds: 260));

    expect(sent.success, isTrue);
    expect(b.queuedDirectCount, 1);
    expect(link.transmitted, isNotEmpty);
  });

  test('CLI set name updates the cached record and survives restart', () async {
    await manager.load();
    await start();
    final node = manager.activeNode!;

    expect(await node.runCliCommand('set name CLI Renamed'), 'OK');
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(manager.activeSummary!.name, 'CLI Renamed');
    expect((await repository.records()).single.name, 'CLI Renamed');

    final restarted = IdentityManager(
      repository: repository,
      notifyDebounce: const Duration(milliseconds: 1),
    );
    addTearDown(restarted.dispose);
    await restarted.load();
    expect(restarted.summaries.single.name, 'CLI Renamed');
  });

  test('valid key import updates the record but keeps name and state',
      () async {
    await manager.load();
    final id = manager.summaries.single.id;
    await start();
    final node = manager.activeNode!;
    await node.setAdvertName('Imported Name');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await node.addUpdateContact(Contact(
      publicKey: (await LocalIdentity.generate()).publicKey,
      name: 'Existing Peer',
    ));
    final candidate = await LocalIdentity.generate();

    await node.importPrivateKey(candidate.meshcore64);
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(node.identity.publicKey, candidate.publicKey);
    final summary = manager.summaries.firstWhere((summary) => summary.id == id);
    expect(summary.publicKey, candidate.publicKey);
    expect(summary.prefixHex,
        bytesToHex(candidate.publicKey.sublist(0, 4)).toUpperCase());
    expect(summary.name, 'Imported Name');
    expect(summary.contactCount, 1);
    final record = (await repository.records()).single;
    expect(record.id, id);
    expect(record.publicKey, candidate.publicKey);
    expect(record.name, 'Imported Name');
  });

  test('importing another identity key is rejected', () async {
    await manager.load();
    final second = await repository.create(name: 'Second');
    await start();
    final secondKey = await keyFor(second.id);
    final firstNode = manager.runtimes
        .firstWhere((runtime) => runtime.record.id == manager.activeId)
        .node!;
    final before = Uint8List.fromList(firstNode.identity.publicKey);

    await expectLater(
      firstNode.importPrivateKey(secondKey.meshcore64),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeIllegalArg)),
    );

    expect(firstNode.identity.publicKey, before);
    final record = (await repository.records())
        .firstWhere((record) => record.id == manager.activeId);
    expect(record.publicKey, before);
  });

  test('importing the attached radio key is rejected while attached', () async {
    await manager.load();
    final deviceIdentity = await LocalIdentity.generate();
    await manager.startLive(
      base: link,
      physical: const PhysicalCapabilities(firmwareVerCode: 14),
      radioParams: link.initialRadioParams,
      devicePublicKey: deviceIdentity.publicKey,
    );
    final node = manager.activeNode!;
    final before = Uint8List.fromList(node.identity.publicKey);

    await expectLater(
      node.importPrivateKey(deviceIdentity.meshcore64),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeIllegalArg)),
    );

    expect(node.identity.publicKey, before);
    expect((await repository.records()).single.publicKey, before);
  });

  test('confirmed RF changes propagate without retuning on activation',
      () async {
    await manager.load();
    final second = await repository.create(name: 'Second');
    await start();
    final a = manager.activeNode!;
    final b = manager.runtimes
        .firstWhere((runtime) => runtime.record.id == second.id)
        .node!;

    await a.setRadioParams(869525000, 125000, 9, 6, clientRepeat: true);
    await a.setTxPower(14);
    await a.setTuningParams(12, 34);
    await a.setPathHashMode(2);

    expect(b.radioParams.frequencyHz, 869525000);
    expect(b.radioParams.bandwidthHz, 125000);
    expect(b.radioParams.spreadingFactor, 9);
    expect(b.radioParams.txPowerDbm, 14);
    expect(b.tuningParams.rxDelayBaseMs, 12);
    expect(b.tuningParams.airtimeFactorMs, 34);
    expect(b.getDeviceInfo().clientRepeat, 1);
    expect(b.prefs.pathHashMode, 0,
        reason: 'path-hash mode remains identity-local');
    expect(a.prefs.pathHashMode, 2);

    final writesBefore = link.calls
        .where((call) =>
            call == 'setRadioParams' ||
            call == 'setTxPower' ||
            call == 'setTuningParams')
        .length;
    await manager.activate(second.id);
    final writesAfter = link.calls
        .where((call) =>
            call == 'setRadioParams' ||
            call == 'setTxPower' ||
            call == 'setTuningParams')
        .length;

    expect(writesAfter, writesBefore,
        reason: 'activation must not retune the shared radio');
    expect(manager.activeNode!.getSelfInfo().frequencyHz, 869525000);
    expect(manager.activeNode!.getSelfInfo().pathHashMode, 0);
    final tuning = await manager.activeNode!.getTuningParams();
    expect(tuning.rxDelayBaseMs, 12);
    expect(tuning.airtimeFactorMs, 34);
  });

  test('create_is_inactive_and_delete_removes_files', () async {
    await manager.load();
    final first = manager.summaries.single.id;
    final second = await manager.create(name: 'Second');

    expect(manager.activeId, first);
    final summary =
        manager.summaries.firstWhere((summary) => summary.id == second.id);
    expect(summary.active, isFalse);
    expect(await repository.loadKey(second.id), isNotNull);

    await manager.delete(second.id);

    expect(manager.summaries, hasLength(1));
    expect(await repository.loadKey(second.id), isNull);
    expect(await repository.stateFile(second.id).exists(), isFalse);
    expect(
      () => manager.delete(first),
      throwsA(isA<IdentityDeleteException>()),
    );
  });

  test('clear_local_data_keeps_name_and_key', () async {
    await manager.load();
    final id = manager.summaries.single.id;
    await start();
    final node = manager.activeNode!;
    await node.setAdvertName('Keep Me');
    await node.addUpdateContact(Contact(
      publicKey: (await LocalIdentity.generate()).publicKey,
      name: 'Peer',
    ));

    await manager.clearLocalData(id);

    expect(manager.activeNode!.prefs.nodeName, 'Keep Me');
    expect(manager.activeNode!.contacts, isEmpty);
    expect(manager.activeSummary!.queuedTotal, 0);
    expect(await repository.loadKey(id), isNotNull);
  });

  test('corrupt index yields a recoverable database error', () async {
    final file = File('${dir.path}/identities/index.json');
    await file.parent.create(recursive: true);
    await file.writeAsString('{broken');

    await manager.load();

    expect(manager.loaded, isFalse);
    expect(manager.databaseError, contains('unreadable'));
  });
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

var _seed = 100;

class _FailingStore extends InMemoryNodeStore {
  _FailingStore(this.initial);

  final NodeState initial;
  bool failSave = true;
  int flushes = 0;

  @override
  Future<NodeState?> load() async => initial.copy();

  @override
  Future<void> save(NodeState state) async {
    if (failSave) throw const FileSystemException('reset save failed');
    await super.save(state);
  }

  @override
  Future<void> flush() async {
    flushes++;
  }
}

class _CountingIdentityPersistence implements VirtualIdentityPersistence {
  _CountingIdentityPersistence(this.stored);

  LocalIdentity? stored;
  int saves = 0;
  Object? saveError;

  @override
  Future<LocalIdentity?> load() async => stored;

  @override
  Future<void> save(LocalIdentity identity) async {
    saves++;
    if (saveError != null) throw saveError!;
    stored = identity;
  }
}

Future<LocalIdentity> _seedIdentity(int value) =>
    LocalIdentity.fromSeed(Uint8List(32)..[0] = value);

Future<NodeState> _populatedState(LocalIdentity identity) async {
  final peer = await _seedIdentity(120);
  return NodeState(
    prefs: NodePrefs(
      nodeName: 'Old Name',
      pathHashMode: 2,
      multiAcks: 4,
      timezoneOffsetHours: -5,
    ),
    contacts: [
      Contact(publicKey: peer.publicKey, name: 'Old Contact'),
    ],
    channels: {
      3: Channel(
        name: 'Old Channel',
        secret: Uint8List.fromList(List.filled(16, 7)),
      ),
    },
    queue: [QueuedMessage(senderKey: peer.publicKey, text: 'Old Queue')],
    advertPaths: {
      'aabbccddeeff00': AdvertPath(
        publicKeyPrefix: Uint8List.fromList(
          [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0],
        ),
        name: 'Old Path',
        pathLen: 1,
        path: Uint8List.fromList([1]),
      ),
    },
    customSettings: {'gps': '1'},
  );
}

void _expectFreshState(NodeState state) {
  expect(state.prefs.nodeName, 'MeshChameleon');
  expect(state.prefs.pathHashMode, 0);
  expect(state.prefs.multiAcks, 0);
  expect(state.prefs.timezoneOffsetHours, 0);
  expect(state.contacts, isEmpty);
  expect(state.channels.keys, [0]);
  expect(state.channels[0]?.name, 'Public');
  expect(
    state.channels[0]?.secret,
    LocalIdentity.defaultPublicChannelSecret,
  );
  expect(state.queue, isEmpty);
  expect(state.advertPaths, isEmpty);
  expect(state.customSettings, isEmpty);
}

void main() {
  test('data_only_reset_keeps_key_resets_virtual_data', () async {
    final identity = await _seedIdentity(_seed++);
    final store = InMemoryNodeStore();
    await store.save(await _populatedState(identity));
    final persistence = _CountingIdentityPersistence(identity);
    final node = MeshNode(
      identity: identity,
      link: FakeDeviceLink(),
      store: store,
      identityPersistence: persistence,
    );
    await node.load();

    final result = await node.resetVirtualData();

    expect(result.success, isTrue);
    expect(result.dataReset, isTrue);
    expect(result.identityRotated, isFalse);
    expect(result.keyError, isNull);
    expect(node.identity.publicKey, identity.publicKey);
    expect(persistence.saves, 0);
    _expectFreshState((await store.load())!);
    expect(node.prefs.nodeName, 'MeshChameleon');
    expect(node.contacts, isEmpty);
    expect(node.getChannel(0)?.name, 'Public');
    expect(node.getChannel(3), isNull);
    expect(await node.syncNextMessage(), isNull);
  });

  test('data_and_key_reset_uses_new_key_after_success', () async {
    final identity = await _seedIdentity(_seed++);
    final store = InMemoryNodeStore();
    await store.save(await _populatedState(identity));
    final persistence = _CountingIdentityPersistence(identity);
    final node = MeshNode(
      identity: identity,
      link: FakeDeviceLink(),
      store: store,
      identityPersistence: persistence,
    );
    await node.load();

    final result = await node.resetVirtualData(rotateIdentity: true);

    expect(result.success, isTrue);
    expect(result.dataReset, isTrue);
    expect(result.identityRotated, isTrue);
    expect(result.keyError, isNull);
    expect(node.identity.publicKey, isNot(identity.publicKey));
    expect(persistence.saves, 1);
    expect(persistence.stored?.publicKey, node.identity.publicKey);
    expect(
      await LocalIdentity.validateMeshcore64(node.identity.meshcore64),
      isTrue,
    );
    _expectFreshState((await store.load())!);
  });

  test('state_save_failure_preserves_old_state_and_reports_failure', () async {
    final identity = await _seedIdentity(_seed++);
    final initial = await _populatedState(identity);
    final store = _FailingStore(initial);
    final node = MeshNode(
      identity: identity,
      link: FakeDeviceLink(),
      store: store,
    );
    await node.load();

    await expectLater(
      node.resetVirtualData(),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeFileIoError)),
    );

    expect(store.flushes, 1);
    expect(node.prefs.nodeName, 'Old Name');
    expect(node.contacts.single.name, 'Old Contact');
    expect(node.getChannel(3)?.name, 'Old Channel');
    expect(
        node.getAdvertPath(
          Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0]),
        ),
        isNotNull);
    store.failSave = false;
    expect((await node.syncNextMessage())?.text, 'Old Queue');
    expect(node.identity.publicKey, identity.publicKey);
  });

  test('key_save_failure_after_data_reset_reports_partial_result_honestly',
      () async {
    final identity = await _seedIdentity(_seed++);
    final store = InMemoryNodeStore();
    await store.save(await _populatedState(identity));
    final persistence = _CountingIdentityPersistence(identity)
      ..saveError = const FileSystemException('key save failed');
    final node = MeshNode(
      identity: identity,
      link: FakeDeviceLink(),
      store: store,
      identityPersistence: persistence,
    );
    await node.load();

    final result = await node.resetVirtualData(rotateIdentity: true);

    expect(result.dataReset, isTrue);
    expect(result.identityRotated, isFalse);
    expect(result.success, isFalse);
    expect(result.partialKeyFailure, isTrue);
    expect(result.keyError?.code, errCodeFileIoError);
    expect(node.identity.publicKey, identity.publicKey,
        reason: 'old identity remains active after a partial reset');
    // The data reset is durable and is not rolled back.
    _expectFreshState((await store.load())!);
    expect(node.contacts, isEmpty);
    expect(node.getChannel(3), isNull);
  });

  test('reset_flush_cannot_resurrect_old_state_after_reload', () async {
    final dir = await Directory.systemTemp.createTemp('mesh_reset_flush_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/node_state.json');
    final identity = await _seedIdentity(_seed++);
    final store = JsonNodeStore(file: file);
    final initial = await _populatedState(identity);
    await store.save(initial);
    final node =
        MeshNode(identity: identity, link: FakeDeviceLink(), store: store);
    await node.load();

    // Queue an older snapshot write directly against the store, then reset.
    // The reset must flush that write before persisting the fresh state.
    final oldSave = store.save(initial.copy()
      ..prefs.nodeName = 'Queued Old'
      ..contacts.clear());
    final reset = node.resetVirtualData();
    await Future.wait([oldSave, reset]);

    final reloaded = MeshNode(
      identity: identity,
      link: FakeDeviceLink(),
      store: JsonNodeStore(file: file),
    );
    await reloaded.load();
    expect(reloaded.prefs.nodeName, 'MeshChameleon');
    expect(reloaded.prefs.pathHashMode, 0);
    expect(reloaded.contacts, isEmpty);
    expect(reloaded.channels.keys, [0]);
    expect(reloaded.getChannel(0)?.name, 'Public');
    expect(reloaded.getChannel(3), isNull);
    expect(reloaded.advertPathCacheLength, 0);
    expect(await reloaded.syncNextMessage(), isNull);
    expect(reloaded.getCustomVars(), isEmpty);
  });

  test('reset_makes_zero_physical_writes', () async {
    final identity = await _seedIdentity(_seed++);
    final link = FakeDeviceLink();
    await link.connect();
    final node = MeshNode(
      identity: identity,
      link: link,
      store: InMemoryNodeStore(),
    );
    await node.load();
    await node.resetVirtualData(rotateIdentity: true);
    await node.resetVirtualData();

    expect(link.calls.where((c) => c == 'sendRawPacket'), isEmpty);
    expect(link.calls.where((c) => c == 'reboot'), isEmpty);
    expect(link.calls.where((c) => c == 'shutdown'), isEmpty);
    expect(link.calls.where((c) => c == 'runCliCommand'), isEmpty);
    expect(link.calls.where((c) => c == 'setRadioParams'), isEmpty);
    expect(link.calls.where((c) => c == 'setTxPower'), isEmpty);
    expect(link.calls.where((c) => c == 'setTuningParams'), isEmpty);
  });
}

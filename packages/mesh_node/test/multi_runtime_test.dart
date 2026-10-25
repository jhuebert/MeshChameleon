import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  Future<MeshNode> makeNode({
    InMemoryNodeStore? store,
    LocalIdentity? identity,
    FakeDeviceLink? link,
    void Function()? onStateChanged,
  }) async {
    final node = MeshNode(
      identity: identity ?? await LocalIdentity.generate(),
      link: link ?? FakeDeviceLink(),
      store: store,
      onStateChanged: onStateChanged,
    );
    await node.load();
    node.start();
    return node;
  }

  test('summary getters count persistent state only', () async {
    final peer = await LocalIdentity.generate();
    final another = await LocalIdentity.generate();
    final store = InMemoryNodeStore();
    await store.save(NodeState(
      prefs: NodePrefs(nodeName: 'Summary'),
      contacts: [
        Contact(publicKey: peer.publicKey, name: 'Peer'),
        Contact(publicKey: another.publicKey, name: 'Another'),
      ],
      channels: {
        0: Channel(
          name: 'Public',
          secret: Uint8List.fromList(LocalIdentity.defaultPublicChannelSecret),
        ),
        2: Channel(
          name: 'Extra',
          secret: Uint8List.fromList(List.filled(16, 1)),
        ),
      },
      queue: [
        QueuedMessage(senderKey: peer.publicKey, text: 'dm'),
        QueuedMessage(senderKey: Uint8List(32), text: 'channel', isChannel: true),
      ],
    ));
    final node = await makeNode(store: store);
    addTearDown(node.retire);

    expect(node.persistentContactCount, 2);
    expect(node.channelCount, 2);
    expect(node.queuedMessageCount, 2);
    expect(node.queuedDirectCount, 1);
    expect(node.queuedChannelCount, 1);
  });

  test('clear_local_data_keeps_name_and_identity', () async {
    final peer = await LocalIdentity.generate();
    final store = InMemoryNodeStore();
    await store.save(NodeState(
      prefs: NodePrefs(nodeName: 'Kept Name', pathHashMode: 2),
      contacts: [Contact(publicKey: peer.publicKey, name: 'Peer')],
      channels: {
        0: Channel(
          name: 'Public',
          secret: Uint8List.fromList(LocalIdentity.defaultPublicChannelSecret),
        ),
        3: Channel(
          name: 'Extra',
          secret: Uint8List.fromList(List.filled(16, 2)),
        ),
      },
      queue: [QueuedMessage(senderKey: peer.publicKey, text: 'dm')],
    ));
    final node = await makeNode(store: store);
    addTearDown(node.retire);
    final identity = Uint8List.fromList(node.identity.publicKey);

    final result = await node.resetVirtualData(preserveName: true);

    expect(result.dataReset, isTrue);
    expect(result.identityRotated, isFalse);
    expect(node.identity.publicKey, identity);
    expect(node.prefs.nodeName, 'Kept Name');
    expect(node.contacts, isEmpty);
    expect(node.channels.keys, [0]);
    expect(node.queuedMessageCount, 0);
    final persisted = await store.load();
    expect(persisted!.prefs.nodeName, 'Kept Name');
    expect(persisted.contacts, isEmpty);
  });

  test('queue drain emits state notifications', () async {
    var changes = 0;
    final peer = await LocalIdentity.generate();
    final store = InMemoryNodeStore();
    await store.save(NodeState(
      prefs: NodePrefs(),
      queue: [
        QueuedMessage(senderKey: peer.publicKey, text: 'one'),
        QueuedMessage(senderKey: peer.publicKey, text: 'two'),
      ],
    ));
    final node = await makeNode(
      store: store,
      onStateChanged: () => changes++,
    );
    addTearDown(node.retire);
    changes = 0;

    expect(await node.syncNextMessage(), isNotNull);
    expect(await node.syncNextMessage(), isNotNull);
    expect(changes, 2);
    expect(node.queuedMessageCount, 0);
    expect(await node.syncNextMessage(), isNull);
  });

  test('shared physical state sync updates RF and tuning only', () async {
    final node = await makeNode();
    addTearDown(node.retire);

    node.syncPhysicalState(
      params: const RadioParams(
        frequencyHz: 869525000,
        bandwidthHz: 125000,
        spreadingFactor: 9,
        codingRate: 6,
        txPowerDbm: 14,
      ),
      tuning: const TuningParams(rxDelayBaseMs: 12, airtimeFactorMs: 34),
    );

    expect(node.radioParams.frequencyHz, 869525000);
    expect(node.radioParams.txPowerDbm, 14);
    expect(node.tuningParams.rxDelayBaseMs, 12);
    expect(node.prefs.nodeName, 'MeshChameleon');
    expect(node.prefs.pathHashMode, 0);
  });

  test('retired node refuses new work and transmissions', () async {
    final link = FakeDeviceLink();
    await link.connect();
    final node = await makeNode(link: link);
    await link.disconnect();
    await node.retire();

    expect(node.retired, isTrue);
    expect(await node.sendControlData(Uint8List.fromList([1, 2])), isFalse);
    expect(await node.advertise(), isFalse);
    expect(link.transmitted, isEmpty);
    expect(() => node.start(), throwsStateError);
  });
}

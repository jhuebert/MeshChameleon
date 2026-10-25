import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

class _Sink implements CompanionPushSink {
  final List<int> confirmed = [];
  final List<List<int>> rawData = [];
  final List<List<int>> controlData = [];
  final List<Uint8List> rawRx = [];
  int msgWaiting = 0;

  @override
  void pushSendConfirmed(int ackCrc) => confirmed.add(ackCrc);

  @override
  void pushRawData(double snr, int rssi, Uint8List payload) =>
      rawData.add([...payload]);

  @override
  void pushControlData(double snr, int rssi, int pathLen, Uint8List data) =>
      controlData.add([pathLen, ...data]);

  @override
  void pushRawRxData(double snr, int rssi, Uint8List raw) =>
      rawRx.add(Uint8List.fromList(raw));

  @override
  void pushMsgWaiting() => msgWaiting++;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Router implements LocalPeerRouter {
  final List<MeshNode> nodes = [];
  final List<Uint8List> mirrored = [];
  Uint8List? blocked;

  void register(MeshNode node) => nodes.add(node);

  @override
  bool isBlockedPeer(Uint8List publicKey) =>
      blocked != null && _equal(blocked!, publicKey);

  @override
  Future<void> mirrorOutbound(
    Uint8List packet, {
    required Uint8List fromPublicKey,
  }) async {
    mirrored.add(Uint8List.fromList(packet));
    for (final node in List<MeshNode>.of(nodes)) {
      if (_equal(node.identity.publicKey, fromPublicKey)) continue;
      try {
        await node.receiveLocal(packet);
      } catch (_) {
        // Mirrors are best-effort per peer.
      }
    }
  }
}

class _ImmediateScheduler implements MeshScheduler {
  @override
  CancelScheduled schedule(Duration delay, void Function() action) {
    // Run protocol delays synchronously; leave long periodic work (battery)
    // unarmed so it cannot recurse.
    if (delay <= const Duration(seconds: 10)) action();
    return () {};
  }
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  late _Router router;

  setUp(() => router = _Router());

  Future<MeshNode> makeNode({
    required String name,
    FakeDeviceLink? link,
    MeshScheduler? scheduler,
  }) async {
    final node = MeshNode(
      identity: await LocalIdentity.generate(),
      link: link ?? FakeDeviceLink(),
      store: InMemoryNodeStore(),
      localRouter: router,
      scheduler: scheduler ?? const TimerMeshScheduler(),
      prefs: NodePrefs(nodeName: name),
    );
    await node.load();
    node.start();
    router.register(node);
    return node;
  }

  Future<void> connectPeers(MeshNode a, MeshNode b, {int pathLen = 0}) async {
    await a.addUpdateContact(Contact(
      publicKey: b.identity.publicKey,
      name: 'Peer B',
      outPathLen: pathLen,
      outPath: pathLen == 0
          ? Uint8List(0)
          : Uint8List.fromList(List.filled(pathLen, 0xAA)),
    ));
    await b.addUpdateContact(Contact(
      publicKey: a.identity.publicKey,
      name: 'Peer A',
      outPathLen: pathLen,
      outPath: pathLen == 0
          ? Uint8List(0)
          : Uint8List.fromList(List.filled(pathLen, 0xBB)),
    ));
  }

  Future<void> shareChannel(MeshNode a, MeshNode b) async {
    final secret = Uint8List.fromList(List.generate(16, (i) => i + 1));
    await a.setChannel(1, 'Shared', secret);
    await b.setChannel(1, 'Shared', secret);
  }

  test('DM is RF-sent, locally delivered, ACKed, and confirmed', () async {
    final a = await makeNode(name: 'A');
    final b = await makeNode(name: 'B');
    addTearDown(a.retire);
    addTearDown(b.retire);
    await connectPeers(a, b);
    final aSink = _Sink();
    final bSink = _Sink();
    a.setPushSink(aSink);
    b.setPushSink(bSink);

    final sent = await a.sendTextMessage(b.identity.publicKey, 'hello');

    expect(sent.success, isTrue);
    expect(b.queuedDirectCount, 1);
    expect(a.queuedDirectCount, 0, reason: 'sender is excluded from mirror');
    expect(a.link, isA<FakeDeviceLink>());
    expect((a.link as FakeDeviceLink).transmitted, hasLength(1));
    expect(router.mirrored.single, (a.link as FakeDeviceLink).transmitted.single,
        reason: 'mirror copies keep the exact RF bytes');

    await Future<void>.delayed(const Duration(milliseconds: 260));

    expect((b.link as FakeDeviceLink).transmitted, isNotEmpty);
    expect(aSink.confirmed, contains(sent.expectedAck));
    expect(aSink.rawRx, isEmpty, reason: 'mirror copies never emit raw-RX');
    expect(bSink.rawRx, isEmpty, reason: 'mirror copies never emit raw-RX');
  });

  test('pending ACK is registered before a synchronous mirror', () async {
    final a = await makeNode(
      name: 'A',
      scheduler: _ImmediateScheduler(),
    );
    final b = await makeNode(
      name: 'B',
      scheduler: _ImmediateScheduler(),
    );
    addTearDown(a.retire);
    addTearDown(b.retire);
    await connectPeers(a, b);
    final aSink = _Sink();
    a.setPushSink(aSink);

    final sent = await a.sendTextMessage(b.identity.publicKey, 'sync ack');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(sent.success, isTrue);
    expect(b.queuedDirectCount, 1);
    expect((b.link as FakeDeviceLink).transmitted, isNotEmpty);
    expect(aSink.confirmed, contains(sent.expectedAck));
  });

  test('a failed RF dispatch is not mirrored locally', () async {
    final a = await makeNode(name: 'A');
    final b = await makeNode(name: 'B');
    addTearDown(a.retire);
    addTearDown(b.retire);
    await connectPeers(a, b);
    final link = a.link as FakeDeviceLink;
    link.rawTxError = StateError('radio unavailable');

    await expectLater(
      a.sendTextMessage(b.identity.publicKey, 'lost'),
      throwsA(isA<StateError>()),
    );

    expect(link.transmitted, isEmpty);
    expect(b.queuedDirectCount, 0);
  });

  test('local delivery works when the direct path is not consumed', () async {
    final a = await makeNode(name: 'A');
    final b = await makeNode(name: 'B');
    addTearDown(a.retire);
    addTearDown(b.retire);
    await connectPeers(a, b, pathLen: 1);

    final sent = await a.sendTextMessage(b.identity.publicKey, 'routed');

    expect(sent.success, isTrue);
    expect(sent.isFlood, isFalse);
    expect(b.queuedDirectCount, 1);
  });

  test('group text reaches the peer while one packet is RF-sent', () async {
    final a = await makeNode(name: 'A');
    final b = await makeNode(name: 'B');
    addTearDown(a.retire);
    addTearDown(b.retire);
    await shareChannel(a, b);

    expect(await a.sendChannelMessage(1, 'hello channel'), isTrue);

    expect(b.queuedChannelCount, 1);
    expect(a.queuedChannelCount, 0);
    final groupPackets = (a.link as FakeDeviceLink)
        .transmitted
        .where((raw) => Packet.readFrom(raw)?.payloadType == payloadTypeGrpTxt);
    expect(groupPackets, hasLength(1));
  });

  test('group text is not suppressed by a shared display name', () async {
    final a = await makeNode(name: 'Same Name');
    final b = await makeNode(name: 'Same Name');
    addTearDown(a.retire);
    addTearDown(b.retire);
    await shareChannel(a, b);

    await a.sendChannelMessage(1, 'same name');

    expect(b.queuedChannelCount, 1);
  });

  test('group data reaches the peer for flooded and direct sends', () async {
    final a = await makeNode(name: 'A');
    final b = await makeNode(name: 'B');
    addTearDown(a.retire);
    addTearDown(b.retire);
    await shareChannel(a, b);

    expect(
      await a.sendChannelData(1, 1, Uint8List.fromList([1, 2, 3])),
      isTrue,
    );
    expect(
      await a.sendChannelData(
        1,
        2,
        Uint8List.fromList([4, 5]),
        path: const [0xAA],
        pathLenEncoded: 1,
      ),
      isTrue,
    );

    expect(b.queuedChannelCount, 2);
  });

  test('advert mirror teaches the peer the sender contact', () async {
    final a = await makeNode(name: 'Advertiser');
    final b = await makeNode(name: 'Observer');
    addTearDown(a.retire);
    addTearDown(b.retire);

    expect(await a.advertise(), isTrue);

    expect(
      b.contacts.any((c) => _equal(c.publicKey, a.identity.publicKey)),
      isTrue,
    );
  });

  test('control and raw passthrough are both mirrored', () async {
    final a = await makeNode(name: 'A');
    final b = await makeNode(name: 'B');
    addTearDown(a.retire);
    addTearDown(b.retire);
    final sink = _Sink();
    b.setPushSink(sink);

    expect(await a.sendControlData(Uint8List.fromList([7, 8])), isTrue);
    expect(
      await a.sendRawData(Uint8List.fromList([1, 2, 3]), Uint8List(0), 0),
      isTrue,
    );
    expect(
      await a.sendRawData(
        Uint8List.fromList([4, 5, 6]),
        Uint8List.fromList([0xAA]),
        1,
      ),
      isTrue,
    );

    expect(sink.controlData, hasLength(1));
    expect(sink.rawData, hasLength(2),
        reason: 'a local direct packet is final-hop even with a remaining path');
    expect((a.link as FakeDeviceLink).transmitted, hasLength(3));
  });

  test('a duplicate through RF and local paths queues only once', () async {
    final bus = FakeRadioBus();
    final a = await makeNode(
      name: 'A',
      link: FakeDeviceLink(bus: bus),
    );
    final b = await makeNode(
      name: 'B',
      link: FakeDeviceLink(bus: bus),
    );
    addTearDown(a.retire);
    addTearDown(b.retire);
    await (a.link as FakeDeviceLink).connect();
    await (b.link as FakeDeviceLink).connect();
    await connectPeers(a, b);

    await a.sendTextMessage(b.identity.publicKey, 'once');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(b.queuedDirectCount, 1);
  });

  test('a DM to the attached radio identity is rejected', () async {
    final a = await makeNode(name: 'A');
    final b = await makeNode(name: 'B');
    addTearDown(a.retire);
    addTearDown(b.retire);
    await connectPeers(a, b);
    router.blocked = b.identity.publicKey;

    await expectLater(
      a.sendTextMessage(b.identity.publicKey, 'blocked'),
      throwsA(isA<CompanionOperationError>()),
    );
    expect((a.link as FakeDeviceLink).transmitted, isEmpty);
    expect(b.queuedDirectCount, 0);
  });
}

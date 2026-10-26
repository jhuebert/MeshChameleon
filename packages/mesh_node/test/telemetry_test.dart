import 'dart:async';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

class _TestSink implements CompanionPushSink {
  int msgWaiting = 0;
  final List<int> confirmed = [];
  final List<List<int>> telemetry = [];
  final List<List<int>> binary = [];
  final List<List<int>> rawData = [];
  final List<List<int>> rawFrames = [];
  final List<List<int>> control = [];

  @override
  void pushMsgWaiting() => msgWaiting++;

  @override
  void pushSendConfirmed(int ackCrc, {int tripTimeMs = 0}) =>
      confirmed.add(ackCrc);

  @override
  void pushAdvert(Uint8List pubkey) {}

  @override
  void pushNewAdvert(Uint8List contactFrame) {}

  @override
  void pushContactDeleted(Uint8List pubkey) {}

  @override
  void pushContactsFull() {}

  @override
  void pushPathUpdated(Uint8List pubkey) {}

  @override
  void pushTelemetryResponse(Uint8List pubkeyPrefix6, Uint8List data) =>
      telemetry.add([...pubkeyPrefix6, ...data]);

  @override
  void pushBinaryResponse(int tag, Uint8List data) =>
      binary.add([tag, ...data]);

  @override
  void pushRawRxData(double snr, int rssi, Uint8List raw) =>
      rawFrames.add([...raw]);

  @override
  void pushRawData(double snr, int rssi, Uint8List payload) =>
      rawData.add([(snr * 4).round(), rssi, 0xFF, ...payload]);

  @override
  void pushControlData(double snr, int rssi, int pathLen, Uint8List data) =>
      control.add([pathLen, ...data]);

  @override
  void pushPathDiscoveryResponse(Uint8List pubkeyPrefix6, int outPathLen,
      Uint8List outPath, int inPathLen, Uint8List inPath) {}

  @override
  void pushLoginSuccess(Uint8List pubkeyPrefix6,
      {bool legacy = false,
      int permissions = 0,
      int serverTag = 0,
      int acl = 0,
      int firmwareVer = 0}) {}

  @override
  void pushLoginFail(Uint8List pubkeyPrefix6) {}

  @override
  void pushStatusResponse(Uint8List pubkeyPrefix6, Uint8List data) {}

  @override
  void pushTraceData(int pathLen, int flags, int tag, int authCode,
      Uint8List pathHashes, Uint8List pathSnrs, int finalSnrByte) {}
}

class _FakeScheduler implements MeshScheduler {
  int now = 0;
  final List<_Job> jobs = [];

  int get pending => jobs.where((j) => !j.done && !j.cancelled).length;

  @override
  CancelScheduled schedule(Duration delay, void Function() action) {
    final job = _Job(now + delay.inMilliseconds, action);
    jobs.add(job);
    return () => job.cancelled = true;
  }

  void advance(Duration delay) {
    now += delay.inMilliseconds;
    var ran = true;
    while (ran) {
      ran = false;
      for (final job in List<_Job>.of(jobs)) {
        if (!job.done && !job.cancelled && job.at <= now) {
          job.done = true;
          job.action();
          ran = true;
        }
      }
    }
  }

  void resetJobs() {
    jobs.clear();
    now = 0;
  }
}

class _Job {
  _Job(this.at, this.action);
  final int at;
  final void Function() action;
  bool done = false;
  bool cancelled = false;
}

Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 20));

Future<LocalIdentity> _identity(int seed) =>
    LocalIdentity.fromSeed(Uint8List(32)..[0] = seed);

Future<LocalIdentity> _identityWithHashByte(int byte, int start) async {
  var n = start;
  while (true) {
    final seed = Uint8List(32)
      ..[0] = n & 0xFF
      ..[1] = (n >> 8) & 0xFF
      ..[2] = (n >> 16) & 0xFF
      ..[3] = (n >> 24) & 0xFF;
    n++;
    final id = await LocalIdentity.fromSeed(seed);
    if (id.publicKey[0] == (byte & 0xFF)) return id;
  }
}

Future<(MeshNode, FakeDeviceLink, _TestSink, _FakeScheduler)> _makeNode({
  required LocalIdentity identity,
  NodePrefs? prefs,
  int batteryMillivolts = 3700,
  FakeRadioBus? bus,
}) async {
  final link = FakeDeviceLink(
    batteryReading_: BatteryReading(
      millivolts: batteryMillivolts,
      storageUsedKb: 0,
      storageTotalKb: 1024,
    ),
    bus: bus,
  );
  await link.connect();
  final scheduler = _FakeScheduler();
  final sink = _TestSink();
  final node = MeshNode(
    identity: identity,
    link: link,
    prefs: prefs,
    scheduler: scheduler,
  )
    ..setPushSink(sink)
    ..start();
  await pump();
  link.calls.clear();
  link.transmitted.clear();
  scheduler.resetJobs();
  return (node, link, sink, scheduler);
}

Future<Contact> _addContact(
  MeshNode node,
  LocalIdentity peer, {
  int flags = 0,
  int outPathLen = 0,
  List<int> outPath = const [],
}) async {
  final contact = Contact(
    publicKey: peer.publicKey,
    name: 'peer',
    flags: flags,
    outPathLen: outPathLen,
    outPath: outPath,
  );
  await node.addUpdateContact(contact);
  return contact;
}

Future<Packet> _encryptedDataPacket({
  required LocalIdentity from,
  required LocalIdentity to,
  required int payloadType,
  required List<int> body,
  bool flood = false,
  List<int> path = const [],
  int pathLen = 0,
}) async {
  final secret = await from.sharedSecret(to.publicKey);
  final cipher =
      CryptoUtils.encryptThenMac(secret.sublist(0, 16), secret, body);
  final packet = Packet()
    ..header = Packet.createHeader(
      payloadType,
      flood ? routeTypeFlood : routeTypeDirect,
    )
    ..pathLenByte = flood ? 0 : pathLen
    ..path = flood ? Uint8List(0) : Uint8List.fromList(path)
    ..payload = Uint8List.fromList(
      [to.publicKey[0], from.publicKey[0], ...cipher],
    );
  if (flood && path.isNotEmpty) {
    packet
      ..pathLenByte = pathLen
      ..path = Uint8List.fromList(path);
  }
  return packet;
}

Future<Packet> _requestPacket({
  required LocalIdentity from,
  required LocalIdentity to,
  required int tag,
  required int code,
  List<int> data = const [],
  bool flood = false,
  List<int> path = const [],
  int pathLen = 0,
}) {
  final body = BufferWriter()
    ..writeUInt32Le(tag)
    ..writeByte(code)
    ..writeBytes(data);
  return _encryptedDataPacket(
    from: from,
    to: to,
    payloadType: payloadTypeReq,
    body: body.toBytes(),
    flood: flood,
    path: path,
    pathLen: pathLen,
  );
}

Future<Packet> _responsePacket({
  required LocalIdentity from,
  required LocalIdentity to,
  required List<int> body,
}) =>
    _encryptedDataPacket(
      from: from,
      to: to,
      payloadType: payloadTypeResponse,
      body: body,
    );

Future<Uint8List> _decodeTelemetryReply(
  Uint8List raw,
  LocalIdentity requester,
  LocalIdentity responder,
) async {
  final packet = Packet.readFrom(raw)!;
  final secret = await requester.sharedSecret(responder.publicKey);
  if (packet.payloadType == payloadTypeResponse) {
    return CryptoUtils.macThenDecrypt(
      secret.sublist(0, 16),
      secret,
      packet.payload.sublist(2),
    );
  }
  expect(packet.payloadType, payloadTypePath);
  final plain = CryptoUtils.macThenDecrypt(
    secret.sublist(0, 16),
    secret,
    packet.payload.sublist(2),
  );
  final pathLen = plain[0];
  final extraStart = 1 + PathUtils.getByteLength(pathLen);
  expect(plain[extraStart], payloadTypeResponse);
  return plain.sublist(extraStart + 1);
}

void main() {
  test('permission table modes_and_class_flags_and_inverse_mask', () async {
    final alice = await _identity(10);
    final bob = await _identity(11);
    final (node, link, _, scheduler) = await _makeNode(identity: bob);
    addTearDown(node.stop);
    var tag = 1000;

    Future<Uint8List?> ask({
      required int modeBase,
      int modeLoc = teleModeDeny,
      int flags = 0x02,
      int inverse = 0,
    }) async {
      await _addContact(node, alice, flags: flags);
      node.prefs
        ..telemetryModeBase = modeBase
        ..telemetryModeLocation = modeLoc
        ..telemetryModeEnvironment = teleModeDeny;
      scheduler.resetJobs();
      link.transmitted.clear();
      final request = await _requestPacket(
        from: alice,
        to: bob,
        tag: tag++,
        code: reqTypeGetTelemetryData,
        data: [inverse],
      );
      link.deliver(6, -70, request.writeTo());
      await pump();
      scheduler.advance(const Duration(milliseconds: 300));
      await pump();
      if (link.transmitted.isEmpty) return null;
      return _decodeTelemetryReply(
        link.transmitted.single,
        alice,
        bob,
      );
    }

    expect(await ask(modeBase: teleModeDeny), isNull);
    expect(await ask(modeBase: teleModeAllowFlags, flags: 0x02), isNotNull);
    expect(await ask(modeBase: teleModeAllowFlags, flags: 0), isNull);
    expect(await ask(modeBase: teleModeAllowAll, flags: 0), isNotNull);
    expect(await ask(modeBase: 3, flags: 0x02), isNull);
    expect(await ask(modeBase: teleModeAllowAll, inverse: 1), isNull);
    // Base remains required even if location is permitted.
    final noBase = await ask(
      modeBase: teleModeAllowAll,
      modeLoc: teleModeAllowAll,
      inverse: 1,
    );
    expect(noBase, isNull);
    // Mode 1 requires the matching contact class bit.
    final locWithoutFlag = await ask(
      modeBase: teleModeAllowAll,
      modeLoc: teleModeAllowFlags,
      flags: 0,
    );
    expect(locWithoutFlag, isNotNull);
    expect(locWithoutFlag!.contains(0x88), isFalse);
    final locWithFlag = await ask(
      modeBase: teleModeAllowAll,
      modeLoc: teleModeAllowFlags,
      flags: 0x06,
    );
    expect(locWithFlag, isNotNull);
    expect(locWithFlag!.contains(0x88), isTrue);
  });

  test('incoming_telem_reply_uses_virtual_key_coords_and_fresh_physical_voltage',
      () async {
    final alice = await _identity(12);
    final bob = await _identity(13);
    final prefs = NodePrefs()
      ..latitude = 12.3456
      ..longitude = -45.6789
      ..telemetryModeBase = teleModeAllowAll
      ..telemetryModeLocation = teleModeAllowAll;
    final (node, link, _, scheduler) =
        await _makeNode(identity: bob, prefs: prefs, batteryMillivolts: 4000);
    addTearDown(node.stop);
    await _addContact(node, alice, flags: 0);
    await node.battery.refresh(force: true);
    link.batteryReading_ = const BatteryReading(
      millivolts: 3550,
      storageUsedKb: 0,
      storageTotalKb: 1024,
    );
    link.calls.clear();
    scheduler.resetJobs();
    final request = await _requestPacket(
      from: alice,
      to: bob,
      tag: 0x10203040,
      code: reqTypeGetTelemetryData,
      data: [0],
    );
    link.deliver(6, -70, request.writeTo());
    await pump();
    scheduler.advance(const Duration(milliseconds: 300));
    await pump();

    final reply = await _decodeTelemetryReply(
      link.transmitted.single,
      alice,
      bob,
    );
    final r = BufferReader(reply);
    expect(r.readUInt32Le(), 0x10203040);
    expect(
      r.readRemainingBytes().sublist(0, 15),
      [
        1, 0x74, 0x01, 0x63, // 3550 mV = 3.55 V
        1, 0x88, 0x01, 0xE2, 0x40, // lat 12.3456
        0xF9, 0x07, 0xAB, // lon -45.6789
        0, 0, 0, // altitude 0
      ],
    );
    final outgoing = Packet.readFrom(link.transmitted.single)!;
    expect(outgoing.payload[1], bob.publicKey[0],
        reason: 'reply uses the virtual identity source hash');
    expect(link.calls, contains('battery'));
    expect(
      link.calls.where((c) =>
          c == 'setRadioParams' ||
          c == 'setTxPower' ||
          c == 'setTuningParams'),
      isEmpty,
    );
  });

  test('telem_req_flood_gets_path_return_direct_gets_outbound_route', () async {
    final alice = await _identity(14);
    final bob = await _identity(15);
    final (node, link, _, scheduler) = await _makeNode(identity: bob);
    addTearDown(node.stop);
    node.prefs.telemetryModeBase = teleModeAllowAll;
    await _addContact(
      node,
      alice,
      outPathLen: 1,
      outPath: const [0xAA],
    );
    scheduler.resetJobs();

    final direct = await _requestPacket(
      from: alice,
      to: bob,
      tag: 1,
      code: reqTypeGetTelemetryData,
      data: [0],
    );
    link.deliver(6, -70, direct.writeTo());
    await pump();
    scheduler.advance(const Duration(milliseconds: 300));
    await pump();
    final directReply = Packet.readFrom(link.transmitted.single)!;
    expect(directReply.payloadType, payloadTypeResponse);
    expect(directReply.isRouteDirect, isTrue);
    expect(directReply.pathLenByte, 1);
    expect(directReply.path, [0xAA]);

    link.transmitted.clear();
    scheduler.resetJobs();
    final flood = await _requestPacket(
      from: alice,
      to: bob,
      tag: 2,
      code: reqTypeGetTelemetryData,
      data: [0],
      flood: true,
      path: const [0x11, 0x22],
      pathLen: 2,
    );
    link.deliver(6, -70, flood.writeTo());
    await pump();
    scheduler.advance(const Duration(milliseconds: 300));
    await pump();
    final floodReply = Packet.readFrom(link.transmitted.single)!;
    expect(floodReply.payloadType, payloadTypePath);
    expect(floodReply.isRouteFlood, isTrue);
    final extra = await _decodeTelemetryReply(
      link.transmitted.single,
      alice,
      bob,
    );
    expect(BufferReader(extra).readUInt32Le(), 2);
  });

  test('truncated_request_does_not_read_missing_mask_or_emit_data', () async {
    final alice = await _identity(16);
    final bob = await _identity(17);
    final (node, link, sink, scheduler) = await _makeNode(identity: bob);
    addTearDown(node.stop);
    node.prefs.telemetryModeBase = teleModeAllowAll;
    await _addContact(node, alice);
    link.calls.clear();
    scheduler.resetJobs();

    // A REQ whose authenticated body cannot even be decrypted must not read a
    // missing inverse-mask byte or emit anything.
    final truncated = Packet()
      ..header = Packet.createHeader(payloadTypeReq, routeTypeDirect)
      ..payload = Uint8List.fromList([
        bob.publicKey[0],
        alice.publicKey[0],
        1,
        2,
        3,
      ]);
    link.deliver(6, -70, truncated.writeTo());
    await pump();
    scheduler.advance(const Duration(milliseconds: 300));
    await pump();

    expect(link.transmitted, isEmpty);
    expect(link.calls, isNot(contains('battery')));
    expect(sink.telemetry, isEmpty);
    expect(sink.binary, isEmpty);
  });

  test('unmatched_response_emits_8c_00_tag_data_without_pending_request',
      () async {
    final alice = await _identity(18);
    final bob = await _identity(19);
    final (node, link, sink, _) = await _makeNode(identity: bob);
    addTearDown(node.stop);
    await _addContact(node, alice);
    const tag = 0x11223344;
    final body = [tag & 0xFF, (tag >> 8) & 0xFF, (tag >> 16) & 0xFF,
      (tag >> 24) & 0xFF, 0xAA, 0xBB];
    final response = await _responsePacket(from: alice, to: bob, body: body);
    link.deliver(6, -70, response.writeTo());
    await pump();
    expect(sink.binary.single.take(3), [tag, 0xAA, 0xBB]);
    expect(sink.telemetry, isEmpty);
  });

  test('matched_response_keeps_its_special_push_not_duplicate_binary',
      () async {
    final alice = await _identity(20);
    final bob = await _identity(21);
    final (node, link, sink, _) = await _makeNode(identity: bob);
    addTearDown(node.stop);
    await _addContact(node, alice);
    final sent = await node.sendTelemetryRequest(alice.publicKey);
    expect(sent.success, isTrue);
    link.transmitted.clear();
    final tag = sent.expectedAck!;
    final body = BufferWriter()
      ..writeUInt32Le(tag)
      ..writeBytes([1, 0x74, 0x01, 0x23]);
    final response = await _responsePacket(
      from: alice,
      to: bob,
      body: body.toBytes(),
    );
    link.deliver(6, -70, response.writeTo());
    await pump();
    expect(sink.telemetry, hasLength(1));
    expect(sink.telemetry.single.sublist(6, 10), [1, 0x74, 0x01, 0x23]);
    expect(sink.binary, isEmpty);
  });

  test('sensor_push_tag_timestamp_lpp_are_preserved_across_repeated_pushes',
      () async {
    final alice = await _identity(22);
    final bob = await _identity(23);
    final (node, link, sink, _) = await _makeNode(identity: bob);
    addTearDown(node.stop);
    await _addContact(node, alice);
    final pushes = <List<int>>[
      [1, 2, 3, 4, 0xDE, 0xAD, 0xBE, 0xEF],
      [5, 6, 7, 8, 0x01, 0x74, 0x00, 0x64],
    ];
    for (final data in pushes) {
      final body = BufferWriter()
        ..writeUInt32Le(data[0] | (data[1] << 8) | (data[2] << 16) |
            (data[3] << 24))
        ..writeBytes(data.sublist(4));
      final response =
          await _responsePacket(from: alice, to: bob, body: body.toBytes());
      link.deliver(6, -70, response.writeTo());
      await pump();
    }
    expect(sink.binary[0].first, 0x04030201);
    expect(sink.binary[0].sublist(1, 5), [0xDE, 0xAD, 0xBE, 0xEF]);
    expect(sink.binary[1].first, 0x08070605);
    expect(sink.binary[1].sublist(1, 5), [0x01, 0x74, 0x00, 0x64]);
    expect(sink.telemetry, isEmpty);
  });

  test('binary_subscribe8_and_unsubscribe9_send_bytes_unchanged', () async {
    final alice = await _identity(24);
    final bob = await _identity(25);
    final (node, link, _, _) = await _makeNode(identity: bob);
    addTearDown(node.stop);
    await _addContact(node, alice);

    final subscribe = Uint8List.fromList([
      0x08, 0x78, 0x56, 0x34, 0x12, 0x10, 0x00, 0x00, 0x03, 0x01, 0x02,
      0x03,
    ]);
    final unsubscribe = Uint8List.fromList([
      0x09, 0x78, 0x56, 0x34, 0x12, 0x10, 0x00, 0x00, 0x03, 0x01, 0x02,
      0x03,
    ]);
    for (final request in [subscribe, unsubscribe]) {
      link.transmitted.clear();
      final sent = await node.sendBinaryReq(alice.publicKey, request);
      expect(sent.success, isTrue);
      final packet = Packet.readFrom(link.transmitted.single)!;
      final secret = await alice.sharedSecret(bob.publicKey);
      final plain = CryptoUtils.macThenDecrypt(
        secret.sublist(0, 16),
        secret,
        packet.payload.sublist(2),
      );
      expect(plain.sublist(4), request);
    }
  });

  test('hash_collision_tries_valid_sender_pending_tag_requires_expected_sender',
      () async {
    final alice = await _identity(26);
    final bob = await _identity(27);
    final colliding = await _identityWithHashByte(alice.publicKey[0], 100);
    final (node, link, sink, _) = await _makeNode(identity: bob);
    addTearDown(node.stop);
    await _addContact(node, colliding, outPathLen: 0);
    await _addContact(node, alice, outPathLen: 0);
    final sent = await node.sendTelemetryRequest(alice.publicKey);
    link.transmitted.clear();
    final tag = sent.expectedAck!;
    final body = BufferWriter()
      ..writeUInt32Le(tag)
      ..writeBytes([1, 0x74, 0x01, 0x00]);

    final fromWrong = await _responsePacket(
      from: colliding,
      to: bob,
      body: body.toBytes(),
    );
    link.deliver(6, -70, fromWrong.writeTo());
    await pump();
    expect(sink.telemetry, isEmpty);
    expect(sink.binary, hasLength(1));

    final fromExpected = await _responsePacket(
      from: alice,
      to: bob,
      body: body.toBytes(),
    );
    link.deliver(6, -70, fromExpected.writeTo());
    await pump();
    expect(sink.telemetry, hasLength(1));
    expect(sink.binary, hasLength(1));
  });

  test('response_arriving_before_raw_tx_ack_is_not_lost', () async {
    final alice = await _identity(28);
    final bob = await _identity(29);
    final (node, link, sink, _) = await _makeNode(identity: bob);
    addTearDown(node.stop);
    await _addContact(node, alice);
    link.rawTxAck = Completer<void>();

    final pending = node.sendTelemetryRequest(alice.publicKey);
    await pump();
    final request = Packet.readFrom(link.transmitted.single)!;
    final secret = await bob.sharedSecret(alice.publicKey);
    final plain = CryptoUtils.macThenDecrypt(
      secret.sublist(0, 16),
      secret,
      request.payload.sublist(2),
    );
    final tag = BufferReader(plain).readUInt32Le();
    final body = BufferWriter()
      ..writeUInt32Le(tag)
      ..writeBytes([1, 0x74, 0x00, 0x10]);
    final response =
        await _responsePacket(from: alice, to: bob, body: body.toBytes());
    link.deliver(6, -70, response.writeTo());
    await pump();
    expect(sink.telemetry, hasLength(1),
        reason: 'pending tag must be registered before raw TX completes');

    link.rawTxAck!.complete();
    final sent = await pending;
    expect(sent.success, isTrue);
  });

  test('discovery55_roundtrip8e_no_auto_companion_response', () async {
    final alice = await _identity(30);
    final bob = await _identity(31);
    final bus = FakeRadioBus();
    final (a, aLink, aSink, _) = await _makeNode(identity: alice, bus: bus);
    final (b, bLink, bSink, _) = await _makeNode(identity: bob, bus: bus);
    addTearDown(a.stop);
    addTearDown(b.stop);
    aLink.transmitted.clear();
    bLink.transmitted.clear();

    expect(await a.sendControlData(Uint8List.fromList([0x80, 0x01, 0x02])), isTrue);
    await pump();
    expect(bSink.control, [
      [0, 0x80, 1, 2],
    ]);
    expect(bLink.transmitted, isEmpty,
        reason: 'stock companion never auto-answers discovery probes');

    expect(await b.sendControlData(Uint8List.fromList([0x80, 0x03])), isTrue);
    await pump();
    expect(aSink.control, [
      [0, 0x80, 3],
    ]);
  });

  test('raw_custom_rx84_reserved_ff_and_raw_log88_are_distinct', () async {
    final bob = await _identity(32);
    final (node, link, sink, _) = await _makeNode(identity: bob);
    addTearDown(node.stop);
    final packet = PacketBuilder.createRawCustom([1, 2, 3, 4]);
    final raw = packet.writeTo();
    link.deliver(6, -70, raw);
    await pump();
    expect(sink.rawData, [
      [24, -70, 0xFF, 1, 2, 3, 4],
    ]);
    expect(sink.rawFrames, [
      raw,
    ]);
  });

  test('raw_packet_priority_and_supplied_route_path_survive_transport',
      () async {
    final bob = await _identity(33);
    final (node, link, _, _) = await _makeNode(identity: bob);
    addTearDown(node.stop);
    final packet = Packet()
      ..header = Packet.createHeader(payloadTypeRawCustom, routeTypeDirect)
      ..setPath([0xAA, 0xBB], 1)
      ..payload = Uint8List.fromList([9, 8, 7, 6]);
    link.transmitted.clear();
    link.transmitPriorities.clear();
    expect(await node.sendRawPacket(packet, 2), isTrue);
    expect(link.transmitPriorities.single, 2);
    expect(link.transmitted.single, packet.writeTo());
  });

  test('unconsumed_direct_route_or_flood_control_is_logged_not_delivered_or_executed',
      () async {
    final alice = await _identity(34);
    final bob = await _identity(35);
    final (node, link, sink, _) = await _makeNode(identity: bob);
    addTearDown(node.stop);
    await _addContact(node, alice);

    final text = await _encryptedDataPacket(
      from: alice,
      to: bob,
      payloadType: payloadTypeTxtMsg,
      body: [
        ...(BufferWriter()..writeUInt32Le(7)..writeByte(0)).toBytes(),
        ...'in transit'.codeUnits,
        0,
      ],
      path: const [0xAA],
      pathLen: 1,
    );
    link.deliver(6, -70, text.writeTo());
    await pump();
    expect(await node.syncNextMessage(), isNull);
    expect(sink.rawFrames, hasLength(1));

    final control = PacketBuilder.createControlData([0x80, 1])
      ..header = Packet.createHeader(payloadTypeControl, routeTypeFlood)
      ..setPath([0xAA], 1);
    link.deliver(6, -70, control.writeTo());
    await pump();
    expect(sink.control, isEmpty);
    expect(sink.rawFrames, hasLength(2));

    final rawCustom = PacketBuilder.createRawCustom([1, 2])
      ..setPath([0xBB], 1);
    link.deliver(6, -70, rawCustom.writeTo());
    await pump();
    expect(sink.rawData, isEmpty);
    expect(sink.rawFrames, hasLength(3));

    // Early ACK observation still confirms a pending send.
    final sent = await node.sendTextMessage(alice.publicKey, 'hello');
    expect(sent.success, isTrue);
    final crc = sent.expectedAck!;
    final ack = PacketBuilder.createAckPacket(
      (BufferWriter()..writeUInt32Le(crc)).toBytes(),
    )..setPath([0xCC], 1);
    link.deliver(6, -70, ack.writeTo());
    await pump();
    expect(sink.confirmed, contains(crc));
  });
}

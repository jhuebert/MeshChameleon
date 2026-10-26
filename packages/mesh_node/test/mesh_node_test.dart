import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

class RecordingSink implements CompanionPushSink {
  int msgWaiting = 0;
  final List<int> confirmed = [];
  final List<Uint8List> adverts = [];
  final List<Uint8List> rawRxFrames = [];
  final List<Uint8List> newAdverts = [];
  final List<Uint8List> pathUpdated = [];
  final List<Uint8List> contactDeleted = [];
  int contactsFull = 0;
  final List<String> events = [];

  @override
  void pushMsgWaiting() => msgWaiting++;

  @override
  void pushSendConfirmed(int ackCrc) => confirmed.add(ackCrc);

  @override
  void pushAdvert(Uint8List pubkey) {
    adverts.add(pubkey);
    events.add('advert:${bytesToHex(pubkey)}');
  }

  @override
  void pushRawRxData(double snr, int rssi, Uint8List raw) =>
      rawRxFrames.add(Uint8List.fromList(raw));

  final List<List<int>> rawData = [];

  @override
  void pushRawData(double snr, int rssi, Uint8List payload) =>
      rawData.add([(snr * 4).round(), rssi, 0xFF, ...payload]);

  @override
  void pushNewAdvert(Uint8List contactFrame) {
    newAdverts.add(contactFrame);
    events.add('newAdvert');
  }

  @override
  void pushContactDeleted(Uint8List pubkey) {
    contactDeleted.add(pubkey);
    events.add('deleted:${bytesToHex(pubkey)}');
  }

  @override
  void pushContactsFull() {
    contactsFull++;
    events.add('contactsFull');
  }

  @override
  void pushPathUpdated(Uint8List pubkey) {
    pathUpdated.add(pubkey);
    events.add('pathUpdated:${bytesToHex(pubkey)}');
  }

  @override
  void pushTelemetryResponse(Uint8List pubkeyPrefix6, Uint8List data) {
    telemetry.add([...pubkeyPrefix6, ...data]);
  }

  final List<List<int>> telemetry = [];

  final List<List<int>> binaryResponses = [];

  @override
  void pushBinaryResponse(int tag, Uint8List data) {
    binaryResponses.add([tag, ...data]);
  }

  final List<List<int>> pathDiscovery = [];

  @override
  void pushPathDiscoveryResponse(Uint8List pubkeyPrefix6, int outPathLen,
      Uint8List outPath, int inPathLen, Uint8List inPath) {
    pathDiscovery.add([1, outPathLen, ...outPath, inPathLen, ...inPath]);
  }

  final List<List<int>> logins = [];
  final List<Uint8List> loginFails = [];
  final List<List<int>> statuses = [];

  @override
  void pushControlData(double snr, int rssi, int pathLen, Uint8List data) {
    controlData.add([pathLen, ...data]);
  }

  final List<List<int>> controlData = [];

  @override
  void pushLoginSuccess(Uint8List pubkeyPrefix6,
      {bool legacy = false,
      int permissions = 0,
      int serverTag = 0,
      int acl = 0,
      int firmwareVer = 0}) {
    logins.add([legacy ? 1 : 0, permissions, serverTag, acl, firmwareVer]);
  }

  @override
  void pushLoginFail(Uint8List pubkeyPrefix6) => loginFails.add(pubkeyPrefix6);

  @override
  void pushStatusResponse(Uint8List pubkeyPrefix6, Uint8List data) =>
      statuses.add([...pubkeyPrefix6, ...data]);

  final List<List<int>> traces = [];

  @override
  void pushTraceData(int pathLen, int flags, int tag, int authCode,
      Uint8List pathHashes, Uint8List pathSnrs, int finalSnrByte) {
    traces.add([pathLen, flags, tag, authCode, ...pathHashes, ...pathSnrs, finalSnrByte]);
  }
}

class _TestSensorProvider extends VirtualSensorSettingsProvider {
  const _TestSensorProvider();

  @override
  Map<String, String> get initialSettings => const {'mode': 'fast'};

  @override
  bool supports(String key) => key == 'mode';

  @override
  String? normalize(String key, String value) {
    if (key != 'mode') return null;
    return value == 'fast' || value == 'slow' ? value : null;
  }
}

class _FakeJob {
  _FakeJob(this.at, this.action);
  final int at;
  final void Function() action;
  bool done = false;
  bool cancelled = false;
}

class _FakeScheduler implements MeshScheduler {
  int now = 0;
  final List<_FakeJob> jobs = [];

  int get pending => jobs.where((j) => !j.done && !j.cancelled).length;

  List<int> get pendingTimes => jobs
      .where((j) => !j.done && !j.cancelled)
      .map((j) => j.at)
      .toList()
    ..sort();

  @override
  CancelScheduled schedule(Duration delay, void Function() action) {
    final job = _FakeJob(now + delay.inMilliseconds, action);
    jobs.add(job);
    return () => job.cancelled = true;
  }

  void advance(Duration delay) {
    now += delay.inMilliseconds;
    var ran = true;
    while (ran) {
      ran = false;
      for (final job in List<_FakeJob>.of(jobs)) {
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

Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 20));
Future<void> pumpAck() =>
    Future<void>.delayed(const Duration(milliseconds: 260));
Future<void> pumpMultiAck() =>
    Future<void>.delayed(const Duration(milliseconds: 620));

void main() {
  late MeshNode alice;
  late MeshNode bob;
  late RecordingSink aliceSink;
  late RecordingSink bobSink;
  late FakeRadioBus bus;

  Future<(MeshNode, FakeDeviceLink)> makeRadioNode({
    DeviceInfo deviceInfo = const DeviceInfo(firmwareVerCode: 11),
    RadioParams radioParams = const RadioParams(
      frequencyHz: 915000000,
      bandwidthHz: 250000,
      spreadingFactor: 10,
      codingRate: 5,
    ),
    int maxTxPower = 22,
  }) async {
    final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 42);
    final link = FakeDeviceLink(
      deviceInfo_: deviceInfo,
      radioParams_: radioParams,
      maxTxPower: maxTxPower,
    );
    await link.connect();
    final node = MeshNode(
      identity: id,
      link: link,
      physical: PhysicalCapabilities.fromDeviceInfo(
        deviceInfo,
        maxTxPower: maxTxPower,
      ),
    )..start();
    return (node, link);
  }

  Future<void> setUpPair() async {
    bus = FakeRadioBus();
    final aliceId = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 1);
    final bobId = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 2);
    final aliceLink = FakeDeviceLink(bus: bus);
    final bobLink = FakeDeviceLink(bus: bus);
    await aliceLink.connect();
    await bobLink.connect();
    alice = MeshNode(
      identity: aliceId,
      link: aliceLink,
      prefs: NodePrefs(nodeName: 'alice'),
    )..start();
    bob = MeshNode(
      identity: bobId,
      link: bobLink,
      prefs: NodePrefs(nodeName: 'bob'),
    )..start();
    aliceSink = RecordingSink()..let((s) => alice.setPushSink(s));
    bobSink = RecordingSink()..let((s) => bob.setPushSink(s));
  }

  setUp(setUpPair);
  tearDown(() {
    alice.stop();
    bob.stop();
  });

  test('adverts are received and populate contacts', () async {
    await alice.advertise();
    await pump();
    expect(bob.contacts.length, 1);
    expect(bob.contacts.first.name, 'alice');
    expect(bob.contacts.first.publicKey, alice.identity.publicKey);
    // Pinned BaseChatMesh behavior: stored new candidates push ADVERT (0x80).
    expect(bobSink.adverts.length, 1);
    expect(bobSink.newAdverts, isEmpty);
  });

  test('repeated advert from a known contact pushes PUSH_CODE_ADVERT', () async {
    await alice.advertise();
    await pump();
    await alice.advertise();
    await pump();
    expect(bob.contacts.length, 1);
    expect(bobSink.adverts.length, 2);
  });

  test('direct text is delivered, queued, ACKed and confirmed', () async {
    await alice.advertise();
    await bob.advertise();
    await pump();

    final result = await alice.sendTextMessage(
      bob.identity.publicKey,
      'hello bob',
    );
    expect(result.success, isTrue);
    await pumpAck();

    // Bob queued the message for its client.
    expect(bobSink.msgWaiting, 1);
    final msg = await bob.syncNextMessage();
    expect(msg, isNotNull);
    expect(msg!.text, 'hello bob');
    expect(msg.senderKey, alice.identity.publicKey);

    // Alice received the ACK.
    expect(aliceSink.confirmed.length, 1);
    expect(aliceSink.confirmed.first, result.expectedAck);
  });

  test('channel text is delivered on the default channel', () async {
    expect(alice.getChannel(0)?.name, 'Public');
    await alice.sendChannelMessage(0, 'hello channel');
    final echo = (alice.link as FakeDeviceLink).transmitted.last;
    (alice.link as FakeDeviceLink).deliver(6.0, -70, echo);
    await pump();
    expect(await alice.syncNextMessage(), isNull);
    expect(aliceSink.rawRxFrames, hasLength(1));
    expect(bobSink.rawRxFrames, hasLength(1));
    expect(bobSink.msgWaiting, 1);
    final msg = await bob.syncNextMessage();
    expect(msg, isNotNull);
    expect(msg!.isChannel, isTrue);
    expect(msg.text, 'alice: hello channel');
    expect(msg.channelIdx, 0);
  });

  test('channel messages preserve the encoded path hash width', () async {
    final packet = PacketBuilder.createGroupText(
      channel: alice.getChannel(0)!,
      message: 'heard',
      senderName: 'alice',
      timestamp: 1700000000,
    )
      ..pathLenByte = 0x42
      ..path = Uint8List.fromList([1, 2, 3, 4]);
    (bob.link as FakeDeviceLink).deliver(6.0, -70, packet.writeTo());
    await pump();

    final message = await bob.syncNextMessage();
    expect(message, isNotNull);
    expect(message!.pathLen, 0x42);
  });

  test('a direct channel echo from the local name is not queued', () async {
    final packet = PacketBuilder.createGroupText(
      channel: alice.getChannel(0)!,
      message: 'Test',
      senderName: alice.prefs.nodeName,
      timestamp: 1700000001,
    );
    (alice.link as FakeDeviceLink).deliver(6.0, -70, packet.writeTo());
    await pump();
    expect(await alice.syncNextMessage(), isNull);
  });

  test('syncNextMessage drains and returns null when empty', () async {
    await alice.sendChannelMessage(0, 'one');
    await pump();
    expect(await bob.syncNextMessage(), isNotNull);
    expect(await bob.syncNextMessage(), isNull);
  });

  test('duplicate direct packets are re-ACKed but queued only once', () async {
    await alice.advertise();
    await bob.advertise();
    await pump();

    final result = await alice.sendTextMessage(bob.identity.publicKey, 'dedup me');
    expect(result.success, isTrue);
    await pumpAck();
    final raw = (alice.link as FakeDeviceLink).transmitted.last;
    expect(await bob.syncNextMessage(), isNotNull); // the original delivery

    final bobLink = bob.link as FakeDeviceLink;
    final ackedBefore = bobLink.transmitted.length;
    bobLink.deliver(6.0, -70, raw);
    await pumpAck();
    bobLink.deliver(6.0, -70, raw);
    await pumpAck();

    // Not queued again, but ACKed each time (reliability for retransmits).
    expect(await bob.syncNextMessage(), isNull);
    expect(bobLink.transmitted.length - ackedBefore, 2);
  });

  test('duplicate channel packets are queued only once', () async {
    await alice.sendChannelMessage(0, 'dup channel');
    await pump();
    final raw = (alice.link as FakeDeviceLink).transmitted.last;
    expect(await bob.syncNextMessage(), isNotNull);

    final bobLink = bob.link as FakeDeviceLink;
    bobLink.deliver(6.0, -70, raw);
    await pump();
    bobLink.deliver(6.0, -70, raw);
    await pump();
    expect(await bob.syncNextMessage(), isNull);
  });

  test('path discovery request is sent and its response is pushed', () async {
    await alice.advertise();
    await bob.advertise();
    await pump();

    final result = await alice.sendPathDiscoveryReq(bob.identity.publicKey);
    expect(result.success, isTrue);
    expect(result.isFlood, isTrue);
    final tag = result.expectedAck!;

    // Build the returned-path response the peer would send back.
    final secret = await bob.identity.sharedSecret(alice.identity.publicKey);
    final tagBytes = (BufferWriter()..writeUInt32Le(tag)).toBytes();
    final resp = PacketBuilder.createPathReturn(
      destHashByte: alice.identity.publicKey[0],
      srcHashByte: bob.identity.publicKey[0],
      secret: secret,
      path: const [0xAA, 0xBB],
      pathLenEncoded: 2,
      extraType: payloadTypeResponse,
      extra: [...tagBytes, 0, 0, 0, 0],
    );
    (alice.link as FakeDeviceLink).deliver(6.0, -70, resp.writeTo());
    await pump();

    // Pushed as [_, outPathLen, ...outPath, inPathLen, ...inPath].
    expect(aliceSink.pathDiscovery.length, 1);
    final pushed = aliceSink.pathDiscovery.first;
    expect(pushed[1], 2); // outPathLen
    expect(pushed.sublist(2, 4), [0xAA, 0xBB]);
    expect(pushed[4], 0); // inPathLen (no path on the delivered packet)

    // The node also learned the outbound path to the peer.
    final contact = alice.getContactByKey(bob.identity.publicKey);
    expect(contact, isNotNull);
    expect(contact!.outPath, [0xAA, 0xBB]);
  });

  test('login sends an ANON_REQ and pushes login success', () async {
    await alice.advertise();
    await bob.advertise();
    await pump();

    final result = await alice.sendLogin(bob.identity.publicKey, 'secret');
    expect(result.success, isTrue);
    final tag = result.expectedAck!;

    // New-format server response: tag(4) + code(1) + ka(1) + perms(1) + acl(1)
    // ... + firmware(1) at [12].
    final body = Uint8List(13);
    body.setRange(0, 4, (BufferWriter()..writeUInt32Le(tag)).toBytes());
    body[4] = 0; // RESP_SERVER_LOGIN_OK
    body[5] = 4; // keep-alive secs / 16
    body[6] = 1; // permissions (is_admin)
    body[7] = 3; // ACL permissions
    body[12] = 7; // firmware version level
    (alice.link as FakeDeviceLink)
        .deliver(6.0, -70, (await _responsePacket(bob, alice, body)).writeTo());
    await pump();

    expect(aliceSink.loginFails, isEmpty);
    expect(aliceSink.logins.length, 1);
    expect(aliceSink.logins.first, [0, 1, tag, 3, 7]);

    // A successful login with a keep-alive interval opens a session.
    expect(alice.hasConnection(bob.identity.publicKey), isTrue);
    expect(alice.logout(bob.identity.publicKey), isTrue);
    expect(alice.hasConnection(bob.identity.publicKey), isFalse);
  });

  test('login keep-alive sends a request and consumes its ACK', () async {
    await alice.advertise();
    await bob.advertise();
    await pump();

    // Give alice a direct path to bob so keep-alive is permitted.
    await alice.addUpdateContact(Contact(
      publicKey: bob.identity.publicKey,
      name: 'bob',
      outPath: const [0xAA],
      outPathLen: 1,
    ));

    final login = await alice.sendLogin(bob.identity.publicKey, 'secret');
    final tag = login.expectedAck!;
    final body = Uint8List(13);
    body.setRange(0, 4, (BufferWriter()..writeUInt32Le(tag)).toBytes());
    body[4] = 0; // RESP_SERVER_LOGIN_OK
    body[5] = 1; // keep-alive secs / 16 => 16s
    body[6] = 1; // permissions
    (alice.link as FakeDeviceLink)
        .deliver(6.0, -70, (await _responsePacket(bob, alice, body)).writeTo());
    await pump();
    expect(aliceSink.logins.length, 1);

    await alice.sendKeepAlivesNow();
    await pump();

    // The last transmission is a keep-alive REQ.
    final link = alice.link as FakeDeviceLink;
    final req = Packet.readFrom(link.transmitted.last)!;
    expect(req.payloadType, payloadTypeReq);
    final secret = await alice.identity.sharedSecret(bob.identity.publicKey);
    final plain = CryptoUtils.macThenDecrypt(
        secret.sublist(0, 16), secret, req.payload.sublist(2));
    expect(plain[4], reqTypeKeepAlive);

    // Deliver the discrete ACK the server would send; it must be consumed
    // silently and NOT surfaced as SEND_CONFIRMED.
    final digest = CryptoUtils.sha256(
        [...plain.sublist(0, 9), ...alice.identity.publicKey]);
    final ack = Packet()
      ..header = Packet.createHeader(payloadTypeAck, routeTypeDirect)
      ..payload = Uint8List.fromList(digest.sublist(0, 4));
    link.deliver(6.0, -70, ack.writeTo());
    await pump();
    expect(aliceSink.confirmed, isEmpty);
  });

  test('status request pushes a status response', () async {
    await alice.advertise();
    await bob.advertise();
    await pump();

    final result = await alice.sendStatusReq(bob.identity.publicKey);
    expect(result.success, isTrue);
    final tag = result.expectedAck!;
    final body = Uint8List.fromList([
      ...(BufferWriter()..writeUInt32Le(tag)).toBytes(),
      9, 8, 7, 6,
    ]);
    (alice.link as FakeDeviceLink)
        .deliver(6.0, -70, (await _responsePacket(bob, alice, body)).writeTo());
    await pump();

    expect(aliceSink.statuses.length, 1);
    // AES-ECB decrypt returns block-padded plaintext; check the meaningful head.
    expect(aliceSink.statuses.first.sublist(6, 10), [9, 8, 7, 6]);
  });

  test('channel data is delivered, queued once, and deduplicated', () async {
    final payload = Uint8List.fromList([1, 2, 3, 4]);
    final ok = await alice.sendChannelData(0, 0x1234, payload);
    expect(ok, isTrue);
    await pump();
    final msg = await bob.syncNextMessage();
    expect(msg, isNotNull);
    expect(msg!.isChannel, isTrue);
    expect(msg.channelDataType, 0x1234);
    expect(msg.channelDataPayload, payload);

    // A duplicate transmission is not queued again.
    final raw = (alice.link as FakeDeviceLink).transmitted.last;
    (bob.link as FakeDeviceLink).deliver(6.0, -70, raw);
    await pump();
    expect(await bob.syncNextMessage(), isNull);
  });

  test('group_tx157_channel_rx167_are_distinct', () async {
    expect(maxGroupDataLength, 165);
    expect(maxGroupDataLengthOverCompanion, 157);
    expect(maxChannelDataLength, 167);
    final link = alice.link as FakeDeviceLink;
    final before = link.transmitted.length;

    // The stock companion raw-packet frame caps group TX at 157 bytes.
    final maxPayload =
        Uint8List.fromList(List<int>.generate(157, (i) => i & 0xFF));
    expect(await alice.sendChannelData(0, 0x1234, maxPayload), isTrue);
    expect(link.transmitted.length, before + 1);
    final sent = Packet.readFrom(link.transmitted.last)!;
    final channel = alice.getChannel(0)!;
    final secret = Uint8List(32);
    secret.setRange(0, channel.secret.length.clamp(0, 32), channel.secret);
    final plaintext = CryptoUtils.macThenDecrypt(
      secret.sublist(0, 16),
      secret,
      sent.payload.sublist(1),
    );
    expect(plaintext[0] | (plaintext[1] << 8), 0x1234);
    expect(plaintext[2], 157);
    expect(plaintext.sublist(3, 3 + 157), maxPayload);

    // 158 bytes pads to a 186-byte companion frame, which stock 1.18 drops;
    // 165 (the theoretical on-air cap) and 166 are likewise rejected with no
    // partial transmit.
    expect(await alice.sendChannelData(0, 0x1234, Uint8List(158)), isFalse);
    expect(await alice.sendChannelData(0, 0x1234, Uint8List(165)), isFalse);
    expect(await alice.sendChannelData(0, 0x1234, Uint8List(166)), isFalse);
    expect(link.transmitted.length, before + 1, reason: 'no partial transmit');

    // A long path reduces the whole-command budget: 64 path bytes + 107 data
    // fits exactly in the 176-byte companion payload; 108 does not.
    final longPath = List<int>.generate(64, (i) => i);
    // 32 two-byte hashes encode to 64 path bytes; the raw frame then fits only
    // 93 data bytes (96-byte padded plaintext).
    final longPathLen = PathUtils.encodePathLen(2, 32);
    expect(maxGroupDataLengthForCompanionPath(64), 93);
    expect(
      await alice.sendChannelData(
        0,
        0x1234,
        Uint8List(93),
        path: longPath,
        pathLenEncoded: longPathLen,
      ),
      isTrue,
    );
    expect(link.transmitted.length, before + 2);
    expect(
      await alice.sendChannelData(
        0,
        0x1234,
        Uint8List(94),
        path: longPath,
        pathLenEncoded: longPathLen,
      ),
      isFalse,
    );
    expect(link.transmitted.length, before + 2, reason: 'no partial transmit');

    // A path shorter than the declared encoded length is rejected before any
    // path bytes are read or transmitted.
    expect(
      await alice.sendChannelData(
        0,
        0x1234,
        Uint8List(1),
        path: const [1, 2],
        pathLenEncoded: 3,
      ),
      isFalse,
    );
    expect(link.transmitted.length, before + 2);

    // Drain the channel data Alice sent over the shared fake radio bus before
    // exercising Bob's receive-side limit.
    await pump();
    while (await bob.syncNextMessage() != null) {}

    // Channel RX accepts up to 167 application bytes; 168 is dropped.
    final bobChannel = bob.getChannel(0)!;
    final rxMax =
        Uint8List.fromList(List<int>.generate(167, (i) => i & 0xFF));
    (bob.link as FakeDeviceLink)
        .deliver(6.0, -70, _groupDataPacket(bobChannel, 0x1234, rxMax));
    await pump();
    final msg = await bob.syncNextMessage();
    expect(msg, isNotNull);
    expect(msg!.channelDataPayload, rxMax);

    final rxOver =
        Uint8List.fromList(List<int>.generate(168, (i) => (i + 1) & 0xFF));
    (bob.link as FakeDeviceLink)
        .deliver(6.0, -70, _groupDataPacket(bobChannel, 0x1234, rxOver));
    await pump();
    expect(await bob.syncNextMessage(), isNull);
  });

  test('CLI data messages are queued but not ACKed', () async {
    await alice.advertise();
    await bob.advertise();
    await pump();

    final result = await alice.sendTextMessage(
      bob.identity.publicKey,
      'cmd reply',
      txtType: txtTypeCliData,
    );
    expect(result.success, isTrue);
    expect(result.expectedAck, 0);
    await pump();

    final msg = await bob.syncNextMessage();
    expect(msg, isNotNull);
    expect(msg!.txtType, txtTypeCliData);
    expect(msg.text, 'cmd reply');
    // No ACK is expected for CLI data.
    expect(aliceSink.confirmed, isEmpty);
  });

  test('signed direct messages are parsed, queued, and ACKed', () async {
    await alice.advertise();
    await bob.advertise();
    await pump();

    final secret = await bob.identity.sharedSecret(alice.identity.publicKey);
    final plaintext = BufferWriter()
      ..writeUInt32Le(1234)
      ..writeByte(txtTypeSigned << 2)
      ..writeBytes(bob.identity.publicKey.sublist(0, 4)) // sender prefix
      ..writeString('signed hi')
      ..writeByte(0);
    final cipher = CryptoUtils.encryptThenMac(
        secret.sublist(0, 16), secret, plaintext.toBytes());
    final pkt = Packet()
      ..header = Packet.createHeader(payloadTypeTxtMsg, routeTypeFlood)
      ..payload = Uint8List.fromList([
        alice.identity.publicKey[0],
        bob.identity.publicKey[0],
        ...cipher,
      ]);

    final aliceLink = alice.link as FakeDeviceLink;
    final ackedBefore = aliceLink.transmitted.length;
    aliceLink.deliver(6.0, -70, pkt.writeTo());
    await pumpAck();

    final msg = await alice.syncNextMessage();
    expect(msg, isNotNull);
    expect(msg!.txtType, txtTypeSigned);
    expect(msg.text, 'signed hi');
    expect(aliceLink.transmitted.length - ackedBefore, 1); // ACK sent
  });

  test('contact table capacity is enforced (overwrite opt-in)', () async {
    final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 9);
    // Physical capacities are deliberately smaller and must not affect the
    // virtual 500-contact table.
    final link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(maxContacts: 2, maxChannels: 8),
    );
    await link.connect();
    final node = MeshNode(
      identity: id,
      link: link,
      physical: const PhysicalCapabilities(clientRepeat: 1),
    )..start();
    addTearDown(node.stop);

    Contact c(int i) {
      final key = Uint8List(32)
        ..[0] = i & 0xFF
        ..[1] = (i >> 8) & 0xFF;
      return Contact(publicKey: key, name: 'c$i', lastmod: i);
    }

    for (var i = 1; i <= virtualMaxContacts; i++) {
      await node.addUpdateContact(c(i));
    }
    expect(node.contacts.length, virtualMaxContacts);
    // Full; overwrite is disabled by default.
    await expectLater(
      node.addUpdateContact(c(virtualMaxContacts + 1)),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeTableFull)),
    );
    expect(node.contacts.length, virtualMaxContacts);

    // Opt into overwrite-on-full: the oldest non-favourite is replaced.
    node.prefs.autoaddConfig = autoAddOverwriteOldest;
    await node.addUpdateContact(c(virtualMaxContacts + 1));
    expect(node.contacts.length, virtualMaxContacts);
    expect(node.getContactByKey(c(1).publicKey), isNull);
    expect(
        node.getContactByKey(c(virtualMaxContacts + 1).publicKey), isNotNull);
  });

  test('room login includes the sync cursor', () async {
    await alice.advertise();
    await bob.advertise();
    await pump();

    await alice.addUpdateContact(Contact(
      publicKey: bob.identity.publicKey,
      name: 'room',
      advType: advTypeRoom,
      syncSince: 4242,
    ));

    final aliceLink = alice.link as FakeDeviceLink;
    final before = aliceLink.transmitted.length;
    final result = await alice.sendLogin(bob.identity.publicKey, 'pw');
    expect(result.success, isTrue);
    expect(aliceLink.transmitted.length - before, 1);

    // ANON_REQ payload = dest_hash + sender pubkey(32) + cipher.
    final pkt = Packet.readFrom(aliceLink.transmitted.last)!;
    final secret = await alice.identity.sharedSecret(bob.identity.publicKey);
    final plaintext = CryptoUtils.macThenDecrypt(
        secret.sublist(0, 16), secret, pkt.payload.sublist(33));
    final r = BufferReader(plaintext)..skipBytes(4); // tag
    expect(r.readUInt32Le(), 4242); // sync cursor
    expect(
      String.fromCharCodes(r.readRemainingBytes().takeWhile((b) => b != 0)),
      'pw',
    );
  });

  test('multipart ACKs are accepted and extra ACKs sent when multiAcks set',
      () async {
    await alice.advertise();
    await bob.advertise();
    await pump();

    // Give alice a direct path to bob so the DM is routed (not flooded).
    await alice.addUpdateContact(Contact(
      publicKey: bob.identity.publicKey,
      name: 'bob',
      outPath: const [0xAA],
      outPathLen: 1,
    ));
    await bob.addUpdateContact(Contact(
      publicKey: alice.identity.publicKey,
      name: 'alice',
      outPath: const [0xBB],
      outPathLen: 1,
    ));
    bob.prefs.multiAcks = 1;

    final bobLink = bob.link as FakeDeviceLink;
    final before = bobLink.transmitted.length;
    final result = await alice.sendTextMessage(bob.identity.publicKey, 'hi');
    expect(result.isFlood, isFalse);
    await pumpMultiAck();

    // Bob sent a multipart ACK plus the plain ACK.
    expect(bobLink.transmitted.length - before, 2);
    expect(Packet.readFrom(bobLink.transmitted.last)!.payloadType,
        payloadTypeAck);
    expect(Packet.readFrom(bobLink.transmitted[before])!.payloadType,
        payloadTypeMultipart);

    // Alice confirmed exactly once.
    expect(aliceSink.confirmed.length, 1);
    expect(aliceSink.confirmed.first, result.expectedAck);
  });

  test('control data is sent zero-hop and pushed on receive', () async {
    final ok = await alice.sendControlData(Uint8List.fromList([0x80, 1, 2, 3]));
    expect(ok, isTrue);
    await pump();
    expect(bobSink.controlData.length, 1);
    expect(bobSink.controlData.first, [0, 0x80, 1, 2, 3]);
  });

  test('setRadioParams updates prefs and forwards to the device link', () async {
    alice.setRadioParams(869000000, 125000, 11, 5);
    await pump();
    expect(alice.prefs.frequencyHz, 869000000);
    final link = alice.link as FakeDeviceLink;
    expect((await link.radioParams()).frequencyHz, 869000000);
  });

  test('sign delegates to the identity and verifies', () async {
    final message = Uint8List.fromList([1, 2, 3]);
    final sig = await alice.sign(message);
    expect(
      await LocalIdentity.verify(message, sig, alice.identity.publicKey),
      isTrue,
    );
  });

  test('a 64-byte (imported) identity can advertise and message', () async {
    // Simulate import-from-device: rebuild alice from the 64-byte expanded form
    // of its key (as IdentityStore persists and the device exports).
    final imported = await LocalIdentity.fromMeshcore64(alice.identity.meshcore64);
    expect(imported.canSign, isTrue);

    final localBus = FakeRadioBus();
    final importedLink = FakeDeviceLink(bus: localBus);
    final peerLink = FakeDeviceLink(bus: localBus);
    await importedLink.connect();
    await peerLink.connect();
    final importedNode = MeshNode(
      identity: imported,
      link: importedLink,
      prefs: NodePrefs(nodeName: 'imported'),
    )..start();
    final peer = MeshNode(
      identity: bob.identity,
      link: peerLink,
      prefs: NodePrefs(nodeName: 'peer'),
    )..start();
    final peerSink = RecordingSink()..let((s) => peer.setPushSink(s));

    // Advertising requires signing; the peer must accept it and learn us.
    await importedNode.advertise();
    await peer.advertise();
    await pump();
    expect(peer.contacts.length, 1);
    expect(peer.contacts.first.publicKey, imported.publicKey);
    expect(peerSink.adverts.length, 1);
    expect(peerSink.newAdverts, isEmpty);

    // A direct message must be signable and deliverable too.
    final result =
        await importedNode.sendTextMessage(peer.identity.publicKey, 'hi');
    expect(result.success, isTrue);
    await pump();
    final msg = await peer.syncNextMessage();
    expect(msg, isNotNull);
    expect(msg!.text, 'hi');
    expect(msg.senderKey, imported.publicKey);

    importedNode.stop();
    peer.stop();
  });

  test('default flood scope tags flooded sends with transport codes', () async {
    final key = Uint8List.fromList(List.generate(16, (i) => i + 1));
    await alice.setDefaultFloodScope('RegionOne', key);

    await alice.advertise(flood: true);
    await pump();

    final pkt =
        Packet.readFrom((alice.link as FakeDeviceLink).transmitted.last)!;
    expect(pkt.hasTransportCodes, isTrue);
    expect(pkt.payloadType, payloadTypeAdvert);
    expect(pkt.transportCode1, 0);
    expect(
      pkt.transportCode0,
      CryptoUtils.transportCode(key, pkt.payloadType, pkt.payload),
    );

    // A scoped advert is still valid on air and accepted by a peer.
    expect(bob.contacts.length, 1);
    expect(bob.contacts.first.publicKey, alice.identity.publicKey);
  });

  test('flood scope override, unscoped flag, and reboot reset', () async {
    final def = Uint8List(16)..[0] = 1;
    await alice.setDefaultFloodScope('def', def);

    Future<Packet> lastPacket() async => Packet.readFrom(
        (alice.link as FakeDeviceLink).transmitted.last)!;

    // No override: the default scope applies to channel sends.
    await alice.sendChannelMessage(0, 'hi');
    await pump();
    var pkt = await lastPacket();
    expect(pkt.transportCode0,
        CryptoUtils.transportCode(def, pkt.payloadType, pkt.payload));

    // An override replaces the default.
    final over = Uint8List(16)..[0] = 2;
    alice.setFloodScopeKey(over);
    await alice.sendChannelMessage(0, 'hi2');
    await pump();
    pkt = await lastPacket();
    expect(pkt.transportCode0,
        CryptoUtils.transportCode(over, pkt.payloadType, pkt.payload));

    // The unscoped flag removes transport codes entirely.
    alice.setFloodUnscoped();
    await alice.sendChannelMessage(0, 'hi3');
    await pump();
    expect((await lastPacket()).hasTransportCodes, isFalse);

    // reboot clears the override/unscoped flags: back to the default scope.
    await alice.reboot();
    // It also reboots the device (CMD_REBOOT), so saved radio-pref changes take
    // effect in the firmware.
    expect((alice.link as FakeDeviceLink).rebootRequests, 1);
    await alice.sendChannelMessage(0, 'hi4');
    await pump();
    pkt = await lastPacket();
    expect(pkt.transportCode0,
        CryptoUtils.transportCode(def, pkt.payloadType, pkt.payload));
  });

  test('default_custom_settings_empty_unknown_set_fails_not_noop', () async {
    expect(alice.getCustomVars(), isEmpty);
    await expectLater(
      alice.setCustomVar('gps', '1'),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeIllegalArg)),
    );
    await expectLater(
      alice.setCustomVar('region', 'us'),
      throwsA(isA<CompanionOperationError>()),
    );
    expect(alice.getCustomVars(), isEmpty);
  });

  test('settings_survive_reload_without_physical_calls', () async {
    final store = InMemoryNodeStore();
    final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 77);
    final link = FakeDeviceLink();
    final node = MeshNode(
      identity: id,
      link: link,
      store: store,
      sensorSettings: const _TestSensorProvider(),
    );

    await node.setAutoAddConfig(0x06, 2);
    await node.setOtherParams(
      manualAddContacts: 1,
      telemetryModes: 0x26,
      advertLocPolicy: 1,
      multiAcks: 2,
    );
    await node.setAdvertName('café');
    await node.setAdvertLatLon(12.5, -3.25);
    await node.setTimezoneOffsetHours(5);
    await node.setCustomVar('mode', 'slow');

    final saved = await store.load();
    expect(saved!.prefs.autoaddConfig, 0x06);
    expect(saved.prefs.autoaddMaxHops, 2);
    expect(saved.prefs.manualAddContacts, 1);
    expect(saved.prefs.telemetryModes, 0x26);
    expect(saved.prefs.advertLocPolicy, 1);
    expect(saved.prefs.multiAcks, 2);
    expect(saved.prefs.nodeName, 'café');
    expect(saved.prefs.latitude, 12.5);
    expect(saved.prefs.longitude, -3.25);
    expect(saved.prefs.timezoneOffsetHours, 5);
    expect(saved.customSettings, {'mode': 'slow'});

    final relaunchedLink = FakeDeviceLink();
    final relaunched = MeshNode(
      identity: id,
      link: relaunchedLink,
      store: store,
      sensorSettings: const _TestSensorProvider(),
    );
    await relaunched.load();
    expect(relaunched.getAutoAddConfig(), 0x06);
    expect(relaunched.getAutoAddMaxHops(), 2);
    expect(relaunched.getSelfInfo().telemetryModes, 0x26);
    expect(relaunched.getSelfInfo().manualAddContacts, 1);
    expect(relaunched.getSelfInfo().advertLocPolicy, 1);
    expect(relaunched.getSelfInfo().multiAcks, 2);
    expect(relaunched.prefs.nodeName, 'café');
    expect(relaunched.timezoneOffsetHours, 5);
    expect(relaunched.getCustomVars(), {'mode': 'slow'});

    // Virtual settings never write physical radio state.
    expect(link.calls, isEmpty);
    expect(relaunchedLink.calls, isEmpty);
    node.stop();
    relaunched.stop();
  });

  test('other_params_preserve_all_omitted_fields_and_pack_telemetry',
      () async {
    await alice.setOtherParams(
      manualAddContacts: 1,
      telemetryModes: 0x26,
      advertLocPolicy: 1,
      multiAcks: 2,
    );
    expect(alice.prefs.manualAddContacts, 1);
    expect(alice.prefs.telemetryModes, 0x26);
    expect(alice.prefs.advertLocPolicy, 1);
    expect(alice.prefs.multiAcks, 2);

    await alice.setOtherParams(manualAddContacts: 0);
    expect(alice.prefs.manualAddContacts, 0);
    expect(alice.prefs.telemetryModes, 0x26);
    expect(alice.prefs.advertLocPolicy, 1);
    expect(alice.prefs.multiAcks, 2);

    await alice.setAutoAddConfig(0x02, 99);
    expect(alice.getAutoAddConfig(), 0x02);
    expect(alice.getAutoAddMaxHops(), 64);
  });

  test('reset restores virtual preference defaults', () async {
    await alice.setAutoAddConfig(0x06, 2);
    await alice.setOtherParams(
      manualAddContacts: 1,
      telemetryModes: 0x26,
      advertLocPolicy: 1,
      multiAcks: 2,
    );
    await alice.setAdvertName('custom');
    await alice.setAdvertLatLon(12.5, -3.25);
    await alice.setTimezoneOffsetHours(5);

    await alice.resetVirtualState();
    expect(alice.getAutoAddConfig(), 0);
    expect(alice.getAutoAddMaxHops(), 0);
    expect(alice.prefs.manualAddContacts, 0);
    expect(alice.prefs.telemetryModes, 0);
    expect(alice.prefs.advertLocPolicy, 0);
    expect(alice.prefs.multiAcks, 0);
    expect(alice.prefs.nodeName, 'MeshChameleon');
    expect(alice.prefs.latitude, 0.0);
    expect(alice.prefs.longitude, 0.0);
    expect(alice.prefs.timezoneOffsetHours, 0);
    expect(alice.getCustomVars(), isEmpty);
  });

  test('advert_and_self_export_hide_or_include_virtual_gps_together',
      () async {
    await alice.setAdvertLatLon(12.5, -3.25);
    await alice.setOtherParams(
      manualAddContacts: 0,
      advertLocPolicy: 0,
    );
    await alice.advertise();
    await pump();
    var packet = Packet.readFrom(
        (alice.link as FakeDeviceLink).transmitted.last)!;
    var decoded = PacketBuilder.decodeAdvertData(
        packet.payload.sublist(pubKeySize + timestampSize + signatureSize));
    expect(decoded.lat, 0.0);
    expect(decoded.lon, 0.0);
    expect(decoded.flags & advertFlagHasLocation, 0);

    var blob = await alice.exportContact(null);
    var exported = Packet.readFrom(blob!)!;
    decoded = PacketBuilder.decodeAdvertData(
        exported.payload.sublist(pubKeySize + timestampSize + signatureSize));
    expect(decoded.lat, 0.0);

    await alice.setOtherParams(
      manualAddContacts: 0,
      advertLocPolicy: 1,
    );
    await alice.advertise();
    await pump();
    packet = Packet.readFrom((alice.link as FakeDeviceLink).transmitted.last)!;
    decoded = PacketBuilder.decodeAdvertData(
        packet.payload.sublist(pubKeySize + timestampSize + signatureSize));
    expect(decoded.lat, closeTo(12.5, 1e-6));
    expect(decoded.lon, closeTo(-3.25, 1e-6));

    blob = await alice.exportContact(null);
    exported = Packet.readFrom(blob!)!;
    decoded = PacketBuilder.decodeAdvertData(
        exported.payload.sublist(pubKeySize + timestampSize + signatureSize));
    expect(decoded.lat, closeTo(12.5, 1e-6));
    expect(decoded.lon, closeTo(-3.25, 1e-6));
  });

  test('backward_time_rejected_forward_time_used_in_advert_and_message',
      () async {
    final bus = FakeRadioBus();
    final aliceId = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 31);
    final bobId = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 32);
    final aliceLink = FakeDeviceLink(bus: bus);
    final bobLink = FakeDeviceLink(bus: bus);
    await aliceLink.connect();
    await bobLink.connect();
    var monotonic = Duration.zero;
    final clock = VirtualClock(
      hostWallClock: () => DateTime.fromMillisecondsSinceEpoch(100000),
      monotonicClock: () => monotonic,
    );
    final timeAlice = MeshNode(
      identity: aliceId,
      link: aliceLink,
      prefs: NodePrefs(nodeName: 'alice'),
      clock: clock,
    )..start();
    final timeBob = MeshNode(
      identity: bobId,
      link: bobLink,
      prefs: NodePrefs(nodeName: 'bob'),
    )..start();
    addTearDown(timeAlice.stop);
    addTearDown(timeBob.stop);

    expect(timeAlice.getTime(), 100);
    expect(timeAlice.setTime(99), isFalse);
    expect(timeAlice.getTime(), 100);
    expect(timeAlice.setTime(101), isTrue);
    expect(timeAlice.getTime(), 101);

    await timeAlice.setTimezoneOffsetHours(5);
    expect(timeAlice.getTime(), 101,
        reason: 'timezone never changes epoch seconds');
    await timeAlice.advertise();
    await pump();

    final advertPacket = Packet.readFrom(aliceLink.transmitted.last)!;
    expect(
      BufferReader(advertPacket.payload.sublist(pubKeySize)).readUInt32Le(),
      101,
    );
    expect(
      timeBob.getContactByKey(aliceId.publicKey)!.lastAdvertTimestamp,
      101,
    );

    expect(timeAlice.setTime(102), isTrue);
    await timeAlice.sendChannelMessage(0, 'forwarded');
    await pump();
    final msg = await timeBob.syncNextMessage();
    expect(msg, isNotNull);
    expect(msg!.timestamp, 102);
    monotonic += const Duration(seconds: 3);
    expect(
      (await timeAlice.getStats(statsTypeCore))['uptime_secs'],
      3,
      reason: 'uptime follows monotonic time, not virtual wall time',
    );
  });

  test('virtual_time_change_does_not_expire_monotonic_dedup_or_change_host_radio_clock',
      () async {
    final bus = FakeRadioBus();
    final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 33);
    final link = FakeDeviceLink(bus: bus);
    await link.connect();
    var monotonic = Duration.zero;
    final node = MeshNode(
      identity: id,
      link: link,
      clock: VirtualClock(
        hostWallClock: () => DateTime.fromMillisecondsSinceEpoch(200000),
        monotonicClock: () => monotonic,
      ),
    )..start();
    addTearDown(node.stop);

    final packet = PacketBuilder.createGroupText(
      channel: node.getChannel(0)!,
      message: 'dedup me',
      senderName: 'peer',
      timestamp: 200,
    );
    final raw = packet.writeTo();
    link.deliver(6.0, -70, raw);
    await pump();
    expect((await node.getStats(statsTypeCore))['queue_len'], 1);

    final callsBefore = List<String>.of(link.calls);
    final uptimeBefore = (await node.getStats(statsTypeCore))['uptime_secs'];
    expect(node.setTime(200000), isTrue); // jump virtual wall far forward
    expect(link.calls, callsBefore,
        reason: 'no host clock or radio clock write');

    // Dedup TTL is monotonic, so the same packet is still rejected.
    link.deliver(6.0, -70, raw);
    await pump();
    expect((await node.getStats(statsTypeCore))['queue_len'], 1);
    expect((await node.getStats(statsTypeCore))['uptime_secs'], uptimeBefore);

    monotonic += const Duration(seconds: 301);
    link.deliver(6.0, -70, raw);
    await pump();
    expect((await node.getStats(statsTypeCore))['queue_len'], 2,
        reason: 'dedup expires only on monotonic age');
  });

  test('binary request pushes a matching PUSH_CODE_BINARY_RESPONSE', () async {
    await alice.advertise();
    await bob.advertise();
    await pump();

    final result = await alice.sendBinaryReq(
        bob.identity.publicKey, Uint8List.fromList([reqTypeGetStatus, 1, 2]));
    expect(result.success, isTrue);
    final tag = result.expectedAck!;
    expect(tag, isNot(0));
    await pump();

    final body = Uint8List.fromList([
      ...(BufferWriter()..writeUInt32Le(tag)).toBytes(),
      0xAA,
      0xBB,
      0xCC,
    ]);
    (alice.link as FakeDeviceLink)
        .deliver(6.0, -70, (await _responsePacket(bob, alice, body)).writeTo());
    await pump();

    expect(aliceSink.binaryResponses.length, 1);
    final binResp = aliceSink.binaryResponses.first;
    expect(binResp.first, tag);
    // AES-ECB returns block-padded plaintext (as on the firmware), so only the
    // meaningful prefix is asserted.
    expect(binResp.sublist(1, 4), [0xAA, 0xBB, 0xCC]);
  });

  test('anonymous request auto-adds the contact and pushes its response',
      () async {
    await alice.advertise();
    await bob.advertise();
    await pump();

    final result = await alice
        .sendAnonReq(bob.identity.publicKey, Uint8List.fromList([1, 0]));
    expect(result.success, isTrue);
    final tag = result.expectedAck!;
    await pump();

    final body = Uint8List.fromList([
      ...(BufferWriter()..writeUInt32Le(tag)).toBytes(),
      5,
      6,
      7,
      8,
    ]);
    (alice.link as FakeDeviceLink)
        .deliver(6.0, -70, (await _responsePacket(bob, alice, body)).writeTo());
    await pump();

    expect(aliceSink.binaryResponses.length, 1);
    final anonResp = aliceSink.binaryResponses.first;
    expect(anonResp.first, tag);
    expect(anonResp.sublist(1, 5), [5, 6, 7, 8]);
  });

  test('exportContact(self) returns a valid advert blob', () async {
    final blob = await alice.exportContact(null);
    expect(blob, isNotNull);
    final pkt = Packet.readFrom(blob!)!;
    expect(pkt.payloadType, payloadTypeAdvert);
    expect(pkt.payload.sublist(0, pubKeySize), alice.identity.publicKey);
    expect(await PacketBuilder.verifyAdvert(pkt.payload), isTrue);
  });

  test('exportContact returns the received raw advert blob', () async {
    await alice.advertise();
    await pump();

    final blob = await bob.exportContact(alice.identity.publicKey);
    expect(blob, isNotNull);
    final pkt = Packet.readFrom(blob!)!;
    expect(pkt.payloadType, payloadTypeAdvert);
    expect(pkt.payload.sublist(0, pubKeySize), alice.identity.publicKey);

    expect(await bob.exportContact(Uint8List(32)..[0] = 99), isNull);
  });

  test('importContact adds a contact from a shared blob', () async {
    await alice.advertise();
    await pump();

    final blob = await bob.exportContact(alice.identity.publicKey);
    final carolLink = FakeDeviceLink(bus: bus);
    await carolLink.connect();
    final carol = MeshNode(
      identity: await LocalIdentity.fromSeed(Uint8List(32)..[0] = 3),
      link: carolLink,
      prefs: NodePrefs(nodeName: 'carol'),
    )..start();
    final carolSink = RecordingSink()..let((s) => carol.setPushSink(s));

    expect(await carol.importContact(blob!), isTrue);
    await pump();
    expect(carol.contacts.length, 1);
    expect(carol.contacts.first.publicKey, alice.identity.publicKey);
    expect(carolSink.adverts.length, 1);
    expect(carolSink.newAdverts, isEmpty);

    // A non-advert blob is rejected.
    expect(await carol.importContact(Uint8List.fromList([1, 2, 3])), isFalse);
    carol.stop();
  });

  test('shareContact re-transmits the saved advert zero-hop', () async {
    await alice.advertise();
    await pump();

    final bobLink = bob.link as FakeDeviceLink;
    bobLink.transmitted.clear();
    expect(await bob.shareContact(alice.identity.publicKey), isTrue);
    await pump();

    expect(bobLink.transmitted.length, 1);
    final pkt = Packet.readFrom(bobLink.transmitted.single)!;
    expect(pkt.payloadType, payloadTypeAdvert);
    expect(pkt.isRouteDirect, isTrue);
    expect(pkt.path, isEmpty);

    expect(await bob.shareContact(Uint8List(32)..[0] = 99), isFalse);
  });

  test('getAllowedRepeatFreq delegates to the device link', () async {
    final ranges = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
    final link = FakeDeviceLink(allowedRepeatFreq: ranges);
    await link.connect();
    final node = MeshNode(
      identity: await LocalIdentity.fromSeed(Uint8List(32)..[0] = 9),
      link: link,
      prefs: NodePrefs(nodeName: 'regs'),
    )..start();
    expect(await node.getAllowedRepeatFreq(), ranges);
    node.stop();
  });

  test('sendRawData transmits a direct raw custom packet with the path',
      () async {
    final aliceLink = alice.link as FakeDeviceLink;
    aliceLink.transmitted.clear();

    final ok = await alice.sendRawData(
      Uint8List.fromList([9, 8, 7, 6]),
      Uint8List.fromList([0xAA, 0xBB]),
      0x02,
    );
    expect(ok, isTrue);
    await pump();

    expect(aliceLink.transmitted.length, 1);
    final pkt = Packet.readFrom(aliceLink.transmitted.single)!;
    expect(pkt.payloadType, payloadTypeRawCustom);
    expect(pkt.routeType, routeTypeDirect);
    expect(pkt.path, [0xAA, 0xBB]);
    expect(pkt.payload, [9, 8, 7, 6]);
  });

  test('sendRawPacket transmits the packet verbatim with its route', () async {
    final aliceLink = alice.link as FakeDeviceLink;
    aliceLink.transmitted.clear();

    final packet = Packet()
      ..header = Packet.createHeader(payloadTypeTxtMsg, routeTypeDirect)
      ..payload = Uint8List.fromList([1, 2, 3, 4]);
    packet.setPath([0xAA, 0xBB]);

    expect(await alice.sendRawPacket(packet, 0), isTrue);
    await pump();
    expect(aliceLink.transmitted.single, packet.writeTo());
  });

  test('telemetry request encodes the inverse permission mask', () async {
    await bob.advertise();
    await pump();

    final result = await alice.sendTelemetryRequest(
      bob.identity.publicKey,
      wantEnvironment: false,
    );
    expect(result.success, isTrue);
    expect(result.expectedAck, isNotNull);

    final sent = (alice.link as FakeDeviceLink).transmitted.last;
    final packet = Packet.readFrom(sent)!;
    expect(packet.payloadType, payloadTypeReq);
    final secret = await alice.identity.sharedSecret(bob.identity.publicKey);
    final plaintext = CryptoUtils.macThenDecrypt(
        secret.sublist(0, 16), secret, packet.payload.sublist(2));
    final r = BufferReader(plaintext);
    r.readUInt32Le(); // tag
    expect(r.readByte(), reqTypeGetTelemetryData);
    expect(r.readByte(), telemPermEnvironment);
  });

  test('telemetry request pushes a matching telemetry response', () async {
    await alice.advertise();
    await bob.advertise();
    await pump();

    final result = await alice.sendTelemetryRequest(bob.identity.publicKey);
    expect(result.success, isTrue);
    final tag = result.expectedAck!;
    final lpp = Uint8List.fromList([1, 0x67, 0x00, 0x01, 0x02]);
    final body = Uint8List.fromList([
      ...(BufferWriter()..writeUInt32Le(tag)).toBytes(),
      ...lpp,
    ]);
    (alice.link as FakeDeviceLink)
        .deliver(6.0, -70, (await _responsePacket(bob, alice, body)).writeTo());
    await pump();

    expect(aliceSink.telemetry.length, 1);
    expect(aliceSink.telemetry.first.sublist(6, 11), lpp);
  });

  test('flood packet path length uses the configured hash width', () async {
    await alice.setPathHashMode(2);
    await alice.sendChannelMessage(0, 'three-byte path mode');

    final packet = Packet.readFrom((alice.link as FakeDeviceLink).transmitted.last)!;
    expect(packet.pathHashSize, 3);
    expect(packet.pathHashCount, 0);

    await alice.setPathHashMode(1);
    await alice.sendChannelMessage(0, 'two-byte path mode');
    final twoBytePacket =
        Packet.readFrom((alice.link as FakeDeviceLink).transmitted.last)!;
    expect(twoBytePacket.pathHashSize, 2);
    expect(twoBytePacket.pathHashCount, 0);
  });

  test('virtual_path_mode_never_reaches_device', () async {
    final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 5);
    for (final fw in [9, 10, 14]) {
      for (final mode in [0, 1, 2]) {
        final info = DeviceInfo(firmwareVerCode: fw);
        final link = FakeDeviceLink(deviceInfo_: info);
        await link.connect();
        final store = InMemoryNodeStore();
        final node = MeshNode(
          identity: id,
          link: link,
          physical: PhysicalCapabilities.fromDeviceInfo(info),
          store: store,
        )..start();

        await node.setPathHashMode(mode);
        await pump();

        expect(node.getPathHashMode(), mode, reason: 'fw $fw mode $mode');
        expect((await store.load())!.prefs.pathHashMode, mode,
            reason: 'fw $fw mode $mode persisted');
        expect(link.calls, isNot(contains('setPathHashMode')),
            reason: 'fw $fw mode $mode must stay virtual');
        expect(link.pathHashMode, 0, reason: 'physical mode untouched');
        node.stop();
      }
    }
  });

  test('reconnect_and_radio_sync_preserve_virtual_path_mode', () async {
    final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 6);
    const info = DeviceInfo(firmwareVerCode: 14); // physical path mode 0
    final link = FakeDeviceLink(deviceInfo_: info);
    await link.connect();
    final store = InMemoryNodeStore();
    final physical = PhysicalCapabilities.fromDeviceInfo(info);
    final node =
        MeshNode(identity: id, link: link, physical: physical, store: store)
          ..start();
    await node.setPathHashMode(2);
    await pump();
    expect(node.getPathHashMode(), 2);

    // Reload persisted state and re-sync physical RF values, as attach or a
    // reconnect does.
    final relaunched =
        MeshNode(identity: id, link: link, physical: physical, store: store);
    await relaunched.load();
    relaunched.syncRadioParams(await link.radioParams());

    expect(relaunched.getPathHashMode(), 2);
    expect(relaunched.prefs.pathHashMode, 2);
    expect(link.calls, isNot(contains('setPathHashMode')));
    expect(link.pathHashMode, 0);
    relaunched.stop();
    node.stop();
  });

  test('radio_swap_cannot_change_virtual_board_key_capacities_or_path_mode',
      () async {
    final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 7);
    const first = DeviceInfo(
      firmwareVerCode: 13,
      maxContacts: 2,
      maxChannels: 8,
      manufacturer: 'First Radio',
      version: 'fw 1.0',
      clientRepeat: 1,
      pathHashMode: 2,
    );
    final node = MeshNode(
      identity: id,
      link: FakeDeviceLink(deviceInfo_: first),
      physical: PhysicalCapabilities.fromDeviceInfo(first, maxTxPower: 17),
      prefs: NodePrefs(nodeName: 'virtual node'),
    );
    addTearDown(node.stop);
    await node.setPathHashMode(1);

    final before = node.getDeviceInfo();
    expect(before.firmwareVerCode, targetFirmwareVerCode);
    expect(before.version, targetCompatibilityVersion);
    expect(before.manufacturer, virtualBoardName);
    expect(before.maxContacts, virtualMaxContacts);
    expect(before.maxChannels, virtualMaxChannels);
    expect(before.blePin, 0);
    expect(before.clientRepeat, 1);
    expect(node.getPathHashMode(), 1);
    expect(node.maxChannels, virtualMaxChannels);

    const second = DeviceInfo(
      firmwareVerCode: 12,
      maxContacts: 1000,
      maxChannels: 4,
      manufacturer: 'Second Radio',
      version: 'fw 2.0',
      clientRepeat: 0,
      pathHashMode: 0,
    );
    node.adoptPhysicalCapabilities(
      PhysicalCapabilities.fromDeviceInfo(second, maxTxPower: 5),
    );

    final after = node.getDeviceInfo();
    expect(after.firmwareVerCode, before.firmwareVerCode);
    expect(after.manufacturer, virtualBoardName);
    expect(after.version, before.version);
    expect(after.maxContacts, virtualMaxContacts);
    expect(after.maxChannels, virtualMaxChannels);
    expect(after.blePin, 0);
    // The physical repeat byte controls the modem, so it follows the radio.
    expect(after.clientRepeat, 0);
    expect(node.getPublicKey(), id.publicKey);
    expect(node.getPathHashMode(), 1);
    expect(node.prefs.pathHashMode, 1);
    expect(node.maxChannels, virtualMaxChannels);
    expect(node.physical.firmwareVerCode, 12);
    expect(node.physical.maxTxPower, 5);
    expect(node.prefs.maxTxPower, 5);
    await node.setChannel(39, 'c39', Uint8List(16));
    await expectLater(
      node.setChannel(40, 'c40', Uint8List(16)),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeNotFound)),
    );
  });

  test('legacy over-capacity contacts load non-destructively', () async {
    final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 10);
    Contact c(int i) {
      final key = Uint8List(32)
        ..[0] = i & 0xFF
        ..[1] = (i >> 8) & 0xFF;
      return Contact(publicKey: key, name: 'legacy$i', lastmod: i + 1);
    }

    final legacy = List<Contact>.generate(virtualMaxContacts + 1, c);
    final store = InMemoryNodeStore();
    await store.save(NodeState(prefs: NodePrefs(), contacts: legacy));
    final node = MeshNode(
      identity: id,
      link: FakeDeviceLink(),
      store: store,
    );
    await node.load();

    expect(node.contacts.length, virtualMaxContacts + 1);
    expect(node.getContacts().length, virtualMaxContacts + 1);
    // Additions are rejected at the cap, but no existing record is dropped.
    await expectLater(
      node.addUpdateContact(c(virtualMaxContacts + 5)),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeTableFull)),
    );
    expect(node.contacts.length, virtualMaxContacts + 1);
    expect(node.getContactByKey(c(0).publicKey), isNotNull);
  });

  test('physical_fw_gates_cli_not_virtual_protocol_code', () async {
    final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 8);
    const info = DeviceInfo(firmwareVerCode: 13);
    final link = FakeDeviceLink(deviceInfo_: info);
    final node = MeshNode(
      identity: id,
      link: link,
      physical: PhysicalCapabilities.fromDeviceInfo(info),
    )..start();
    addTearDown(node.stop);

    // Physical fw13 cannot run the physical CLI, but the virtual CLI still does.
    expect(await node.runCliCommand('ver'), virtualCliVersion);
    expect(await node.runCliCommand('get radio'), 'Error: unsupported');
    expect(link.calls, isNot(contains('runCliCommand')));

    // ...but virtual protocol information is independent of that firmware.
    expect(node.getDeviceInfo().firmwareVerCode, targetFirmwareVerCode);
    expect(node.getDeviceInfo().version, targetCompatibilityVersion);
    expect(node.getDeviceInfo().manufacturer, virtualBoardName);
    // The virtual CLI lands in T11 and must be gated by virtual state, not
    // physical fw13.
  });

  test('physical_max_tx_and_signed_tx_are_adopted', () async {
    final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 9);
    final link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14, clientRepeat: 1),
      radioParams_: const RadioParams(
        frequencyHz: 915000000,
        bandwidthHz: 250000,
        spreadingFactor: 10,
        codingRate: 5,
        txPowerDbm: -3,
      ),
      maxTxPower: 17,
    );
    await link.connect();
    final node = MeshNode(identity: id, link: link)..start();
    addTearDown(node.stop);
    expect(node.prefs.maxTxPower, defaultMaxTxPowerDbm);

    final deviceInfo = await link.deviceInfo();
    final selfInfo = await link.selfInfo();
    expect(selfInfo.maxTxPower, 17);
    node.adoptPhysicalCapabilities(PhysicalCapabilities.fromDeviceInfo(
      deviceInfo,
      maxTxPower: selfInfo.maxTxPower,
    ));
    node.syncRadioParams(selfInfo.radioParams);

    expect(node.physical.maxTxPower, 17);
    expect(node.prefs.maxTxPower, 17);
    expect(node.prefs.txPowerDbm, -3);
    expect(node.getSelfInfo().maxTxPower, 17);
    expect(node.getDeviceInfo().clientRepeat, 1);
  });

  test('radio_set_has_no_ok_or_cache_change_before_device_ack', () async {
    final (node, link) = await makeRadioNode();
    addTearDown(node.stop);
    final ack = Completer<void>();
    link.radioParamsAck = ack;
    final before = node.prefs.frequencyHz;

    final future = node.setRadioParams(869000000, 125000, 11, 5);
    await pump();

    expect(node.prefs.frequencyHz, before, reason: 'cache unchanged');
    expect(link.calls.where((c) => c == 'setRadioParams').length, 1);

    ack.complete();
    await future;
    expect(node.prefs.frequencyHz, 869000000);
    expect(node.radioCacheVerified, isTrue);
  });

  test('tx_and_tuning_setters_also_await_ack', () async {
    final (node, link) = await makeRadioNode();
    addTearDown(node.stop);

    final txAck = Completer<void>();
    link.txPowerAck = txAck;
    final txFuture = node.setTxPower(10);
    await pump();
    expect(node.prefs.txPowerDbm, 20, reason: 'no TX cache change before ACK');
    txAck.complete();
    await txFuture;
    expect(node.prefs.txPowerDbm, 10);

    final tuningAck = Completer<void>();
    link.tuningAck = tuningAck;
    final tuningFuture = node.setTuningParams(123, 45);
    await pump();
    expect(node.prefs.rxDelayBaseMs, 0,
        reason: 'no tuning cache change before ACK');
    tuningAck.complete();
    await tuningFuture;
    expect(node.prefs.rxDelayBaseMs, 123);
    expect(node.prefs.airtimeFactorMs, 45);
    expect(node.tuningCacheVerified, isTrue);
  });

  test('device_err6_is_preserved_and_cache_unchanged', () async {
    for (final code in [2, 3, 5, 6]) {
      final (node, link) = await makeRadioNode();
      link.radioParamsError = DeviceCommandError.device(code);
      final before = node.prefs.frequencyHz;

      await expectLater(
        node.setRadioParams(869000000, 125000, 11, 5),
        throwsA(isA<CompanionOperationError>()
            .having((e) => e.code, 'code', code)),
      );
      expect(node.prefs.frequencyHz, before);
      expect(link.calls.where((c) => c == 'setRadioParams').length, 1);
      node.stop();
    }
  });

  test('device_disabled_maps_to_one_byte_disabled_error', () async {
    final (node, link) = await makeRadioNode();
    addTearDown(node.stop);
    link.radioParamsError =
        const DeviceCommandError.disabled(message: 'feature disabled');
    await expectLater(
      node.setRadioParams(869000000, 125000, 11, 5),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', respCodeDisabled)
          .having((e) => e.disabled, 'disabled', isTrue)),
    );
  });

  test('disconnected_or_timeout_is_err4_and_cache_uncertain_no_write_retry',
      () async {
    for (final error in const [
      DeviceCommandError.timeout(message: 'timeout'),
      DeviceCommandError.disconnected(message: 'disconnected'),
    ]) {
      final (node, link) = await makeRadioNode();
      link.radioParamsError = error;

      await expectLater(
        node.setRadioParams(869000000, 125000, 11, 5),
        throwsA(isA<CompanionOperationError>()
            .having((e) => e.code, 'code', errCodeBadState)
            .having((e) => e.uncertain, 'uncertain', isTrue)),
      );
      expect(node.radioCacheUncertain, isTrue);
      expect(node.radioCacheVerified, isFalse);
      expect(link.calls.where((c) => c == 'setRadioParams').length, 1,
          reason: 'no automatic write retry');
      node.stop();
    }
  });

  test('ack_then_failed_readback_still_ok_with_unverified_cache', () async {
    final (node, link) = await makeRadioNode();
    addTearDown(node.stop);
    link.selfInfoError =
        const DeviceCommandError.malformed(message: 'bad SELF_INFO');

    await node.setRadioParams(869000000, 125000, 11, 5);

    expect(node.prefs.frequencyHz, 869000000,
        reason: 'confirmed requested values are kept');
    expect(node.radioCacheVerified, isFalse);
    expect(node.radioCacheUncertain, isFalse);
    expect(node.physicalDiagnostic, isNotNull);
  });

  test('absent_repeat_preserves_fresh_device_true_and_false', () async {
    for (final repeat in [1, 0]) {
      final (node, link) = await makeRadioNode(
        deviceInfo: DeviceInfo(firmwareVerCode: 10, clientRepeat: repeat),
      );
      await node.setRadioParams(869000000, 125000, 11, 5);
      expect(link.lastClientRepeat, repeat == 1,
          reason: 'fresh DEVICE_INFO repeat is sent explicitly');
      expect(link.calls.where((c) => c == 'deviceInfo').length, 1);
      node.stop();
    }
  });

  test('fresh_repeat_query_failure_produces_no_write', () async {
    final (node, link) = await makeRadioNode(
      deviceInfo: const DeviceInfo(firmwareVerCode: 10),
    );
    addTearDown(node.stop);
    link.deviceInfoError = const DeviceCommandError.timeout();

    await expectLater(
      node.setRadioParams(869000000, 125000, 11, 5),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeBadState)),
    );
    expect(link.calls, isNot(contains('setRadioParams')));
  });

  test('explicit_repeat_validated_and_forwarded', () async {
    final (node, link) = await makeRadioNode(
      deviceInfo: const DeviceInfo(firmwareVerCode: 10),
    );
    addTearDown(node.stop);
    await node.setRadioParams(869000000, 125000, 11, 5, clientRepeat: true);
    expect(link.lastClientRepeat, isTrue);
    await node.setRadioParams(869000000, 125000, 11, 5, clientRepeat: false);
    expect(link.lastClientRepeat, isFalse);

    final (oldNode, oldLink) = await makeRadioNode(
      deviceInfo: const DeviceInfo(firmwareVerCode: 8),
    );
    addTearDown(oldNode.stop);
    await expectLater(
      oldNode.setRadioParams(869000000, 125000, 11, 5, clientRepeat: true),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeUnsupportedCmd)),
    );
    expect(oldLink.calls, isNot(contains('setRadioParams')));

    await oldNode.setRadioParams(869000000, 125000, 11, 5);
    expect(oldLink.lastClientRepeat, isNull,
        reason: 'old firmware omits the optional repeat byte');
  });

  test('writes_and_readbacks_cannot_interleave_with_next_config_transaction',
      () async {
    final (node, link) = await makeRadioNode();
    addTearDown(node.stop);
    final radioAck = Completer<void>();
    final readbackAck = Completer<void>();
    link.radioParamsAck = radioAck;
    link.selfInfoAck = readbackAck;

    final first = node.setRadioParams(869000000, 125000, 11, 5);
    await pump();
    final second = node.setRadioParams(868000000, 125000, 11, 5);
    await pump();
    expect(link.calls.where((c) => c == 'setRadioParams').length, 1);

    radioAck.complete();
    await pump();
    expect(link.calls.where((c) => c == 'setRadioParams').length, 1,
        reason: 'readback is still part of the first transaction');

    readbackAck.complete();
    await Future.wait([first, second]);
    expect(link.calls.where((c) => c == 'setRadioParams').length, 2);
    expect(node.prefs.frequencyHz, 868000000);
  });

  test('raw_rx_processed_while_waiting_for_config_ack', () async {
    final (node, link) = await makeRadioNode();
    final sink = RecordingSink()..let((s) => node.setPushSink(s));
    final ack = Completer<void>();
    link.radioParamsAck = ack;
    final future = node.setRadioParams(869000000, 125000, 11, 5);
    await pump();

    link.deliver(6.0, -70, Uint8List.fromList([1, 2, 3]));
    await pump();
    expect(sink.rawRxFrames.length, 1);

    ack.complete();
    await future;
    node.stop();
  });

  test('tuning_get_uses_last_good_cache_or_err4', () async {
    final (node, link) = await makeRadioNode();
    addTearDown(node.stop);

    link.tuningParamsError = const DeviceCommandError.timeout();
    await expectLater(
      node.getTuningParams(),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeBadState)),
      reason: 'no cache -> ERR4',
    );

    link.tuningParamsError = null;
    await node.setTuningParams(321, 12);
    link.tuningParamsError = const DeviceCommandError.timeout();
    final cached = await node.getTuningParams();
    expect(cached.rxDelayBaseMs, 321);
    expect(cached.airtimeFactorMs, 12);
    expect(node.tuningCacheVerified, isFalse);
  });

  test('signed_and_max_tx_validation_uses_physical_max', () async {
    final (node, link) = await makeRadioNode(
      maxTxPower: 17,
      radioParams: const RadioParams(
        frequencyHz: 915000000,
        bandwidthHz: 250000,
        spreadingFactor: 10,
        codingRate: 5,
        txPowerDbm: -3,
      ),
    );
    addTearDown(node.stop);

    await expectLater(
      node.setTxPower(18),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeIllegalArg)),
    );
    await expectLater(
      node.setTxPower(-10),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeIllegalArg)),
    );
    expect(link.calls, isNot(contains('setTxPower')));

    await node.setTxPower(17);
    expect(node.prefs.txPowerDbm, 17);
    expect(node.prefs.maxTxPower, 17);
  });

  test('core stats report uptime and radio stats track the last frame',
      () async {
    await alice.advertise();
    await pump();

    final core = await alice.getStats(statsTypeCore);
    expect(core['uptime_secs'], isA<int>());

    final radio = await bob.getStats(statsTypeRadio);
    expect(radio['last_rssi'], -70);
    expect(radio['last_snr_scaled'], 24);
    expect(radio['tx_air_secs'], isA<int>());
    expect(radio['rx_air_secs'], isA<int>());
  });

  test('sendTracePathRaw transmits a trace packet', () async {
    final ok = await alice.sendTracePathRaw(0x1234, 0, 0, Uint8List.fromList([1, 2]));
    expect(ok, isTrue);
    final sent = (alice.link as FakeDeviceLink).transmitted.last;
    final packet = Packet.readFrom(sent)!;
    expect(packet.payloadType, payloadTypeTrace);
    expect(packet.routeType, routeTypeDirect);
    final r = BufferReader(packet.payload);
    expect(r.readUInt32Le(), 0x1234);
    expect(r.readUInt32Le(), 0);
    expect(r.readByte(), 0);
    expect(r.readBytes(2), [1, 2]);
  });

  test('a returned trace packet pushes TRACE_DATA', () async {
    final pkt = PacketBuilder.createTrace(
      tag: 0x1111,
      authCode: 0,
      flags: 0,
      path: [0x01, 0x02],
    )..setPath([0x20, 0x30]);
    (alice.link as FakeDeviceLink).deliver(6.0, -70, pkt.writeTo());
    await pump();

    expect(aliceSink.traces.length, 1);
    expect(aliceSink.traces.first, [2, 0, 0x1111, 0, 0x01, 0x02, 0x20, 0x30, 24]);
  });

  test('a partial trace packet is ignored (proxy does not forward traces)',
      () async {
    final pkt = PacketBuilder.createTrace(
      tag: 0x2222,
      authCode: 0,
      flags: 0,
      path: [0x01, 0x02, 0x03],
    )..setPath([0x11]);
    (alice.link as FakeDeviceLink).deliver(6.0, -70, pkt.writeTo());
    await pump();
    expect(aliceSink.traces, isEmpty);
  });

  test('manual0_adds_all_types_even_flags0', () async {
    final types = <int>[0, 1, 2, 3, 4];
    for (var i = 0; i < types.length; i++) {
      final id = await LocalIdentity.fromSeed(
        Uint8List(32)..[0] = 100 + i,
      );
      final advert = await _makeAdvert(
        id,
        type: types[i],
        name: 'type${types[i]}',
        timestamp: 1000 + i,
      );
      (bob.link as FakeDeviceLink).deliver(6.0, -70, advert.writeTo());
      await pump();
    }
    expect(bob.contacts, hasLength(types.length));
    expect(
      bob.contacts.map((c) => c.advType).toSet(),
      types.toSet(),
      reason: 'manual_add bit0=0 permits unknown and known types',
    );
    expect(bobSink.adverts, hasLength(types.length));
    expect(bobSink.newAdverts, isEmpty);
  });

  test('manual1_uses_type_mask', () async {
    bob.prefs.manualAddContacts = 1;
    bob.prefs.autoaddConfig = autoAddChat | autoAddRoom;
    final types = <int>[advTypeChat, advTypeRepeater, advTypeRoom, advTypeSensor, 0];
    for (var i = 0; i < types.length; i++) {
      final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 110 + i);
      final advert = await _makeAdvert(
        id,
        type: types[i],
        name: 'mask${types[i]}',
        timestamp: 1100 + i,
      );
      (bob.link as FakeDeviceLink).deliver(6.0, -70, advert.writeTo());
      await pump();
    }
    expect(
      bob.contacts.map((c) => c.advType).toSet(),
      {advTypeChat, advTypeRoom},
    );
    expect(bobSink.adverts, hasLength(2));
    expect(bobSink.newAdverts, hasLength(3));
    expect(bobSink.contactsFull, 0);
  });

  test('max0_unlimited_max1_zero_hop_max2_one_hop', () async {
    final cases = <({int max, int hashSize, int hops, bool allowed})>[
      (max: 0, hashSize: 1, hops: 3, allowed: true),
      (max: 0, hashSize: 2, hops: 5, allowed: true),
      (max: 0, hashSize: 3, hops: 2, allowed: true),
      (max: 1, hashSize: 1, hops: 0, allowed: true),
      (max: 1, hashSize: 2, hops: 1, allowed: false),
      (max: 2, hashSize: 3, hops: 1, allowed: true),
      (max: 2, hashSize: 1, hops: 2, allowed: false),
    ];
    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      bob.prefs
        ..manualAddContacts = 0
        ..autoaddMaxHops = c.max;
      final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 130 + i);
      final advert = await _makeAdvert(
        id,
        type: advTypeChat,
        name: 'hop$i',
        timestamp: 1200 + i,
        hashSize: c.hashSize,
        hops: c.hops,
      );
      (bob.link as FakeDeviceLink).deliver(6.0, -70, advert.writeTo());
      await pump();
      expect(
        bob.getContactByKey(id.publicKey) != null,
        c.allowed,
        reason: 'max=${c.max} hops=${c.hops} hash=${c.hashSize}',
      );
    }
    await bob.setAutoAddConfig(0, 255);
    expect(bob.getAutoAddMaxHops(), 64);
  });

  test('filtered_candidate_pushes_new_advert_but_is_not_stored', () async {
    bob.prefs
      ..manualAddContacts = 1
      ..autoaddConfig = 0;
    final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 160);
    final advert = await _makeAdvert(
      id,
      type: advTypeChat,
      name: 'filtered',
      timestamp: 1300,
      hashSize: 2,
      hops: 1,
    );
    (bob.link as FakeDeviceLink).deliver(6.0, -70, advert.writeTo());
    await pump();

    expect(bob.getContactByKey(id.publicKey), isNull);
    expect(bob.contacts, isEmpty);
    expect(bobSink.newAdverts, hasLength(1));
    expect(bobSink.adverts, isEmpty);
    expect(bobSink.contactsFull, 0);

    final body = bobSink.newAdverts.single;
    expect(body, hasLength(147));
    expect(body.sublist(0, 32), id.publicKey);
    expect(body[32], advTypeChat);
    expect(body[33], 0);
    expect(body[34], 0xFF);
    expect(body.sublist(35, 99), everyElement(0));
    expect(body.sublist(99, 131).take(8).toList(), 'filtered'.codeUnits);
    expect(body.sublist(99, 131).skip(8), everyElement(0));

    final cached = bob.getAdvertPath(id.publicKey.sublist(0, 7));
    expect(cached, isNotNull);
    expect(cached!.path, advert.path);
    expect(cached.pathLen, advert.pathLenByte);
    expect(bobSink.events.last, 'newAdvert');
  });

  test('stored_candidate_pushes_advert_not_new_advert', () async {
    final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 161);
    final advert = await _makeAdvert(
      id,
      type: advTypeChat,
      name: 'stored',
      timestamp: 1310,
      hashSize: 2,
      hops: 1,
    );
    (bob.link as FakeDeviceLink).deliver(6.0, -70, advert.writeTo());
    await pump();

    expect(bob.getContactByKey(id.publicKey), isNotNull);
    expect(bobSink.adverts, hasLength(1));
    expect(bobSink.newAdverts, isEmpty);
    final contact = bob.getContactByKey(id.publicKey)!;
    expect(contact.outPathLen, -1,
        reason: 'new contact starts outbound-route unknown');
    expect(contact.outPath, isEmpty);
    expect(contact.flags, 0);
    expect(bob.getAdvertPath(id.publicKey.sublist(0, 7)), isNotNull);
  });

  test('full_push_order_is_new_advert_then_full', () async {
    bob.prefs.autoaddConfig = autoAddOverwriteOldest;
    for (var i = 0; i < virtualMaxContacts; i++) {
      bob.contacts.add(Contact(
        publicKey: _testKey(1000 + i),
        name: 'fav$i',
        flags: 0x01,
        lastmod: i + 1,
      ));
    }
    final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 170);
    final advert = await _makeAdvert(
      id,
      type: advTypeChat,
      name: 'nofit',
      timestamp: 1320,
      hashSize: 1,
      hops: 1,
    );
    (bob.link as FakeDeviceLink).deliver(6.0, -70, advert.writeTo());
    await pump();

    expect(bob.contacts, hasLength(virtualMaxContacts));
    expect(bob.getContactByKey(id.publicKey), isNull);
    expect(bobSink.contactDeleted, isEmpty);
    expect(bobSink.newAdverts, hasLength(1));
    expect(bobSink.contactsFull, 1);
    expect(bobSink.events.sublist(bobSink.events.length - 2),
        ['newAdvert', 'contactsFull']);
    expect(bob.getAdvertPath(id.publicKey.sublist(0, 7)), isNotNull);
  });

  test('overwrite_oldest_nonfav_emits_deleted_before_advert', () async {
    bob.prefs.autoaddConfig = autoAddOverwriteOldest;
    for (var i = 0; i < virtualMaxContacts; i++) {
      bob.contacts.add(Contact(
        publicKey: _testKey(2000 + i),
        name: 'slot$i',
        flags: 0,
        lastmod: i < 2 ? 10 : 100 + i,
      ));
    }
    final oldKey = _testKey(2000); // first of the equal-oldest pair
    final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 180);
    final advert = await _makeAdvert(
      id,
      type: advTypeChat,
      name: 'winner',
      timestamp: 1330,
      hashSize: 2,
      hops: 1,
    );
    (bob.link as FakeDeviceLink).deliver(6.0, -70, advert.writeTo());
    await pump();

    expect(bob.contacts, hasLength(virtualMaxContacts));
    expect(bob.getContactByKey(oldKey), isNull);
    expect(bob.getContactByKey(id.publicKey), isNotNull);
    expect(bobSink.contactDeleted, hasLength(1));
    expect(bobSink.contactDeleted.single, oldKey);
    expect(bobSink.adverts, hasLength(1));
    final deleted = bobSink.events.indexOf('deleted:${bytesToHex(oldKey)}');
    final advertEvent =
        bobSink.events.indexOf('advert:${bytesToHex(id.publicKey)}');
    expect(deleted, greaterThanOrEqualTo(0));
    expect(advertEvent, greaterThan(deleted));
    final stored = bob.getContactByKey(id.publicKey)!;
    expect(stored.outPathLen, -1);
    expect(stored.flags, 0);
    expect(stored.rawAdvert, isNotNull);
  });

  test('new_advert_does_not_destroy_permission_flags_or_outbound_path',
      () async {
    final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 190);
    bob.contacts.add(Contact(
      publicKey: id.publicKey,
      name: 'before',
      advType: advTypeChat,
      flags: 0x05,
      outPath: Uint8List.fromList([0xAA, 0xBB]),
      outPathLen: PathUtils.encodePathLen(1, 2),
      lastAdvertTimestamp: 100,
      lastmod: 50,
      gpsLat: 1.2,
      gpsLon: 3.4,
      syncSince: 42,
      rawAdvert: Uint8List.fromList([9, 9]),
    ));
    final advert = await _makeAdvert(
      id,
      type: advTypeRoom,
      name: 'after',
      timestamp: 101,
      hashSize: 2,
      hops: 2,
    );
    advert
      ..header = (advert.header & ~phRouteMask) | routeTypeTransportFlood
      ..transportCode0 = 0x1234
      ..transportCode1 = 0x5678;
    (bob.link as FakeDeviceLink).deliver(6.0, -70, advert.writeTo());
    await pump();

    final c = bob.getContactByKey(id.publicKey)!;
    expect(c.name, 'after');
    expect(c.advType, advTypeRoom);
    expect(c.flags, 0x05);
    expect(c.outPath, [0xAA, 0xBB]);
    expect(c.outPathLen, PathUtils.encodePathLen(1, 2));
    expect(c.syncSince, 42);
    expect(c.gpsLat, closeTo(1.2, 1e-6));
    expect(c.gpsLon, closeTo(3.4, 1e-6));
    expect(c.lastAdvertTimestamp, 101);
    expect(bobSink.adverts, hasLength(1));
    expect(bobSink.pathUpdated, isEmpty);
    final raw = Packet.readFrom(c.rawAdvert!)!;
    expect(raw.routeType, routeTypeFlood);
    expect(raw.hasTransportCodes, isFalse);
    expect(raw.path, advert.path);
  });

  test('stale_equal_timestamp_ignored_and_missing_gps_preserves_old_gps',
      () async {
    final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 200);
    bob.contacts.add(Contact(
      publicKey: id.publicKey,
      name: 'old',
      advType: advTypeChat,
      flags: 0x02,
      outPathLen: -1,
      lastAdvertTimestamp: 100,
      lastmod: 50,
      gpsLat: 8.5,
      gpsLon: 9.5,
      rawAdvert: Uint8List.fromList([7]),
    ));

    for (final ts in [100, 99]) {
      final advert = await _makeAdvert(
        id,
        type: advTypeChat,
        name: 'stale',
        timestamp: ts,
      );
      (bob.link as FakeDeviceLink).deliver(6.0, -70, advert.writeTo());
      await pump();
    }
    var c = bob.getContactByKey(id.publicKey)!;
    expect(c.name, 'old');
    expect(c.lastAdvertTimestamp, 100);
    expect(c.lastmod, 50);
    expect(c.gpsLat, 8.5);
    expect(c.rawAdvert, [7]);
    expect(bobSink.adverts, isEmpty);
    expect(bob.getAdvertPath(id.publicKey.sublist(0, 7)), isNull);

    final noLocation = await _makeAdvert(
      id,
      type: advTypeChat,
      name: 'newer',
      timestamp: 101,
    );
    (bob.link as FakeDeviceLink).deliver(6.0, -70, noLocation.writeTo());
    await pump();
    c = bob.getContactByKey(id.publicKey)!;
    expect(c.name, 'newer');
    expect(c.gpsLat, 8.5);
    expect(c.gpsLon, 9.5);
    expect(c.flags, 0x02);

    final withLocation = await _makeAdvert(
      id,
      type: advTypeChat,
      name: 'located',
      timestamp: 102,
      lat: 5.5,
      lon: 6.5,
    );
    (bob.link as FakeDeviceLink).deliver(6.0, -70, withLocation.writeTo());
    await pump();
    c = bob.getContactByKey(id.publicKey)!;
    expect(c.gpsLat, closeTo(5.5, 1e-6));
    expect(c.gpsLon, closeTo(6.5, 1e-6));
    expect(bobSink.adverts, hasLength(2));
  });

  test('explicit_add_bypasses_auto_filters_blob_import_does_not', () async {
    bob.prefs
      ..manualAddContacts = 1
      ..autoaddConfig = 0;
    final explicitKey = _testKey(250);
    await bob.addUpdateContact(Contact(
      publicKey: explicitKey,
      name: 'manual',
      advType: advTypeChat,
      flags: 0x05,
      outPathLen: 0,
    ));
    expect(bob.getContactByKey(explicitKey), isNotNull);
    expect(bobSink.adverts, isEmpty);
    expect(bobSink.newAdverts, isEmpty);

    final sender = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 211);
    final advert = await _makeAdvert(
      sender,
      type: advTypeChat,
      name: 'imported',
      timestamp: 1400,
    );
    final beforeNew = bobSink.newAdverts.length;
    expect(await bob.importContact(advert.writeTo()), isTrue);
    expect(bobSink.newAdverts.length, beforeNew,
        reason: 'import loopback happens after the binary response');
    await pump();
    expect(bobSink.newAdverts.length, beforeNew + 1);
    expect(bob.getContactByKey(sender.publicKey), isNull,
        reason: 'blob import still observes auto-add filters');
  });

  test('anon_pool_has8_slots_separate_from_persistent_contacts_and_listing',
      () async {
    final keys = <Uint8List>[
      for (var i = 0; i < 9; i++) _testKey(300 + i),
    ];
    for (final key in keys) {
      final result = await bob.sendAnonReq(key, Uint8List.fromList([1]));
      expect(result.success, isTrue);
    }
    expect(bob.contacts, isEmpty);
    expect(bob.getContacts(), isEmpty);
    expect(bob.getContactByKey(keys.first), isNull,
        reason: 'oldest transient slot is reused');
    expect(bob.getContactByKey(keys.last), isNotNull);
    expect(bob.getContactByKeyPrefix(keys.last.sublist(0, 4)), isNotNull);
    expect(bob.getDeviceInfo().maxContacts, virtualMaxContacts);
    expect(bobSink.newAdverts, isEmpty);
    expect(bobSink.adverts, isEmpty);
  });

  test('bad_signature_missing_name_or_truncated_appdata_has_no_state_effect',
      () async {
    final badSigId = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 400);
    final badSig = await _makeAdvert(
      badSigId,
      type: advTypeChat,
      name: 'bad',
      timestamp: 1500,
    );
    badSig.payload[badSig.payload.length - 1] ^= 0xFF;
    (bob.link as FakeDeviceLink).deliver(6.0, -70, badSig.writeTo());
    await pump();

    final noNameId = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 401);
    final noName = await _makeAdvert(
      noNameId,
      type: advTypeChat,
      name: '',
      timestamp: 1501,
    );
    (bob.link as FakeDeviceLink).deliver(6.0, -70, noName.writeTo());
    await pump();

    final truncatedId = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 402);
    final truncated = await _signedAdvert(
      truncatedId,
      const [advertFlagHasLocation, 1, 2, 3],
      timestamp: 1502,
    );
    (bob.link as FakeDeviceLink).deliver(6.0, -70, truncated.writeTo());
    await pump();

    final emptyNameId = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 403);
    final emptyName = await _signedAdvert(
      emptyNameId,
      const [advertFlagHasName],
      timestamp: 1503,
    );
    (bob.link as FakeDeviceLink).deliver(6.0, -70, emptyName.writeTo());
    await pump();

    expect(bob.contacts, isEmpty);
    expect(bobSink.adverts, isEmpty);
    expect(bobSink.newAdverts, isEmpty);
    expect(bobSink.contactsFull, 0);
    expect(bob.getAdvertPath(badSigId.publicKey.sublist(0, 7)), isNull);
  });

  test('route_ff_and_zero_are_distinct', () async {
    final key = _testKey(500);
    await bob.addUpdateContact(Contact(
      publicKey: key,
      name: 'dir',
      advType: advTypeChat,
      outPathLen: 0,
    ));
    var before = (bob.link as FakeDeviceLink).transmitted.length;
    var result = await bob.sendTextMessage(key, 'zero');
    expect(result.success, isTrue);
    var sent = Packet.readFrom(
        (bob.link as FakeDeviceLink).transmitted[before])!;
    expect(sent.routeType, routeTypeDirect);
    expect(sent.pathLenByte, 0);
    expect(sent.path, isEmpty);

    await bob.addUpdateContact(Contact(
      publicKey: key,
      name: 'flood',
      advType: advTypeChat,
      outPathLen: -1,
    ));
    before = (bob.link as FakeDeviceLink).transmitted.length;
    result = await bob.sendTextMessage(key, 'flood');
    expect(result.success, isTrue);
    sent = Packet.readFrom((bob.link as FakeDeviceLink).transmitted[before])!;
    expect(sent.routeType, routeTypeFlood);

    expect(
      Contact(publicKey: key, outPathLen: 0).hasDirectRoute,
      isTrue,
    );
    expect(
      Contact(publicKey: key, outPathLen: -1).hasDirectRoute,
      isFalse,
    );
  });

  test('default_advert_is_zero_hop_explicit1_is_flood', () async {
    await alice.advertise();
    await pump();
    var packet =
        Packet.readFrom((alice.link as FakeDeviceLink).transmitted.last)!;
    expect(packet.payloadType, payloadTypeAdvert);
    expect(packet.routeType, routeTypeDirect);
    expect(packet.pathLenByte, 0);
    expect(packet.path, isEmpty);

    await alice.advertise(flood: true);
    await pump();
    packet = Packet.readFrom((alice.link as FakeDeviceLink).transmitted.last)!;
    expect(packet.routeType, routeTypeFlood);
  });

  test('known_zero_hop_dm_and_ack_are_direct_unknown_ff_is_flood', () async {
    final (a, b, aLink, bLink, scheduler) = await _schedulerPair();
    addTearDown(a.stop);
    addTearDown(b.stop);
    await a.addUpdateContact(Contact(
      publicKey: b.identity.publicKey,
      name: 'b',
      outPathLen: 0,
    ));
    await b.addUpdateContact(Contact(
      publicKey: a.identity.publicKey,
      name: 'a',
      outPathLen: 0,
    ));

    var before = aLink.transmitted.length;
    await a.sendTextMessage(b.identity.publicKey, 'zero route');
    var dm = Packet.readFrom(aLink.transmitted[before])!;
    expect(dm.routeType, routeTypeDirect);
    expect(dm.pathLenByte, 0);
    expect(dm.path, isEmpty);
    await pump();
    scheduler.advance(const Duration(milliseconds: 200));
    await pump();
    final ack = Packet.readFrom(bLink.transmitted.last)!;
    expect(ack.payloadType, payloadTypeAck);
    expect(ack.routeType, routeTypeDirect);
    expect(ack.pathLenByte, 0);
    expect(ack.path, isEmpty);

    // Unknown route: DM floods and a direct packet with no return route gets a
    // flooded ACK rather than a direct zero-hop ACK.
    await b.addUpdateContact(Contact(
      publicKey: a.identity.publicKey,
      name: 'a',
      outPathLen: -1,
    ));
    scheduler.resetJobs();
    bLink.transmitted.clear();
    final direct = await _encryptedTextPacket(
      from: a.identity,
      to: b.identity,
      timestamp: 7000,
      txtType: txtTypePlain,
      text: 'unknown ack route',
    );
    bLink.deliver(6.0, -70, direct.writeTo());
    await pump();
    scheduler.advance(const Duration(milliseconds: 200));
    await pump();
    final floodAck = Packet.readFrom(bLink.transmitted.last)!;
    expect(floodAck.payloadType, payloadTypeAck);
    expect(floodAck.routeType, routeTypeFlood);

    await a.addUpdateContact(Contact(
      publicKey: b.identity.publicKey,
      name: 'b',
      outPathLen: -1,
    ));
    before = aLink.transmitted.length;
    await a.sendTextMessage(b.identity.publicKey, 'flood route');
    dm = Packet.readFrom(aLink.transmitted[before])!;
    expect(dm.routeType, routeTypeFlood);
  });

  test('multi_ack0_vs1_vs3', () async {
    final (a, b, _, bLink, scheduler) = await _schedulerPair();
    addTearDown(a.stop);
    addTearDown(b.stop);
    await a.addUpdateContact(Contact(
      publicKey: b.identity.publicKey,
      name: 'b',
      outPathLen: 0,
    ));
    await b.addUpdateContact(Contact(
      publicKey: a.identity.publicKey,
      name: 'a',
      outPathLen: 0,
    ));

    for (final preference in [0, 1, 3]) {
      b.prefs.multiAcks = preference;
      scheduler.resetJobs();
      bLink.transmitted.clear();
      await a.sendTextMessage(
          b.identity.publicKey, 'multi $preference');
      await pump();
      scheduler.advance(const Duration(milliseconds: 200));
      await pump();
      if (preference == 0) {
        expect(bLink.transmitted, hasLength(1));
        expect(Packet.readFrom(bLink.transmitted.single)!.payloadType,
            payloadTypeAck);
        expect(scheduler.pending, 0);
      } else {
        expect(bLink.transmitted, hasLength(1));
        final multi = Packet.readFrom(bLink.transmitted.single)!;
        expect(multi.payloadType, payloadTypeMultipart);
        expect(multi.payload[0] & 0x0F, payloadTypeAck);
        expect(multi.payload[0] >> 4, 1, reason: 'exactly one redundant ACK');
        expect(multi.payload, hasLength(7),
            reason: 'multipart preserves the six-byte plain ACK payload');
        expect(scheduler.pending, 1);
        scheduler.advance(const Duration(milliseconds: 300));
        await pump();
        expect(bLink.transmitted, hasLength(2));
        final plain = Packet.readFrom(bLink.transmitted.last)!;
        expect(plain.payloadType, payloadTypeAck);
        expect(plain.payload, hasLength(6));
        expect(scheduler.pending, 0);
      }
    }
  });

  test('endpoint_ack_schedule200_then500ms', () async {
    final (a, b, _, bLink, scheduler) = await _schedulerPair();
    addTearDown(a.stop);
    addTearDown(b.stop);
    await a.addUpdateContact(Contact(
      publicKey: b.identity.publicKey,
      name: 'b',
      outPathLen: 0,
    ));
    await b.addUpdateContact(Contact(
      publicKey: a.identity.publicKey,
      name: 'a',
      outPathLen: 0,
    ));
    b.prefs.multiAcks = 1;
    scheduler.resetJobs();
    bLink.transmitted.clear();

    await a.sendTextMessage(b.identity.publicKey, 'schedule');
    await pump();
    expect(scheduler.pendingTimes, [200, 500]);
    scheduler.advance(const Duration(milliseconds: 199));
    await pump();
    expect(bLink.transmitted, isEmpty);
    scheduler.advance(const Duration(milliseconds: 1));
    await pump();
    expect(bLink.transmitted, hasLength(1));
    expect(Packet.readFrom(bLink.transmitted.last)!.payloadType,
        payloadTypeMultipart);
    expect(scheduler.pendingTimes, [500]);
    scheduler.advance(const Duration(milliseconds: 299));
    await pump();
    expect(bLink.transmitted, hasLength(1));
    scheduler.advance(const Duration(milliseconds: 1));
    await pump();
    expect(bLink.transmitted, hasLength(2));
    expect(Packet.readFrom(bLink.transmitted.last)!.payloadType, payloadTypeAck);
  });

  test('plain_ack_has_hash4_extended_attempt_and_entropy_signed_has4',
      () async {
    final (a, b, _, bLink, scheduler) = await _schedulerPair();
    addTearDown(a.stop);
    addTearDown(b.stop);
    await b.addUpdateContact(Contact(
      publicKey: a.identity.publicKey,
      name: 'a',
      outPathLen: 0,
    ));

    final timestamp = 7100;
    const attempt = 2;
    const text = 'plain ack';
    const extendedAttempt = 0xAB;
    final plain = await _encryptedTextPacket(
      from: a.identity,
      to: b.identity,
      timestamp: timestamp,
      txtType: txtTypePlain,
      text: text,
      attempt: attempt,
      extendedAttempt: extendedAttempt,
    );
    bLink.deliver(6.0, -70, plain.writeTo());
    await pump();
    scheduler.advance(const Duration(milliseconds: 200));
    await pump();
    final plainAck = Packet.readFrom(bLink.transmitted.last)!;
    expect(plainAck.payloadType, payloadTypeAck);
    expect(plainAck.payload, hasLength(6));
    final expectedHash = PacketBuilder.ackHash(
      timestamp: timestamp,
      flagsByte: (txtTypePlain << 2) | attempt,
      text: utf8.encode(text),
      senderPubkey: a.identity.publicKey,
    );
    expect(plainAck.payload.sublist(0, 4), expectedHash);
    expect(plainAck.payload[4], extendedAttempt);
    expect(plainAck.payload[5], inInclusiveRange(0, 255));

    scheduler.resetJobs();
    bLink.transmitted.clear();
    final signed = await _encryptedTextPacket(
      from: a.identity,
      to: b.identity,
      timestamp: 7200,
      txtType: txtTypeSigned,
      text: 'signed ack',
      signed: true,
    );
    bLink.deliver(6.0, -70, signed.writeTo());
    await pump();
    scheduler.advance(const Duration(milliseconds: 200));
    await pump();
    final signedAck = Packet.readFrom(bLink.transmitted.last)!;
    expect(signedAck.payloadType, payloadTypeAck);
    expect(signedAck.payload, hasLength(4));
    final signedPlaintext = BufferWriter()
      ..writeUInt32Le(7200)
      ..writeByte(txtTypeSigned << 2)
      ..writeBytes(a.identity.publicKey.sublist(0, 4))
      ..writeString('signed ack')
      ..writeByte(0);
    final signedBytes = signedPlaintext.toBytes();
    final signedEnd = 9 + utf8.encode('signed ack').length;
    final expectedSigned = CryptoUtils.sha256([
      ...signedBytes.sublist(0, signedEnd),
      ...b.identity.publicKey,
    ]).sublist(0, 4);
    expect(signedAck.payload, expectedSigned);
  });

  test('flood_dm_ack_is_path_return_and_duplicate_reacked_not_queued_twice',
      () async {
    final (a, b, aLink, bLink, scheduler) = await _schedulerPair();
    addTearDown(a.stop);
    addTearDown(b.stop);
    final scope = Uint8List.fromList(List.generate(16, (i) => i + 3));
    await b.setDefaultFloodScope('scope', scope);
    await a.addUpdateContact(Contact(
      publicKey: b.identity.publicKey,
      name: 'b',
      outPathLen: -1,
    ));
    await b.addUpdateContact(Contact(
      publicKey: a.identity.publicKey,
      name: 'a',
      outPathLen: -1,
    ));

    await a.sendTextMessage(b.identity.publicKey, 'flood dm');
    await pump();
    scheduler.advance(const Duration(milliseconds: 200));
    await pump();
    var response = Packet.readFrom(bLink.transmitted.last)!;
    expect(response.payloadType, payloadTypePath);
    expect(response.isRouteFlood, isTrue);
    expect(response.hasTransportCodes, isTrue,
        reason: 'virtual flood ACKs preserve scope');
    expect(await b.syncNextMessage(), isNotNull);
    expect(await b.syncNextMessage(), isNull);

    final raw = aLink.transmitted.last;
    final beforeAcks = bLink.transmitted.length;
    scheduler.resetJobs();
    bLink.deliver(6.0, -70, raw);
    await pump();
    scheduler.advance(const Duration(milliseconds: 200));
    await pump();
    bLink.deliver(6.0, -70, raw);
    await pump();
    scheduler.advance(const Duration(milliseconds: 200));
    await pump();
    expect(bLink.transmitted.length - beforeAcks, 2,
        reason: 'each duplicate is re-ACKed');
    expect(await b.syncNextMessage(), isNull,
        reason: 'duplicate packets are not queued twice');
  });

  test('cancelling_node_or_reset_cancels_pending_virtual_ack_schedules',
      () async {
    final (a, b, _, bLink, scheduler) = await _schedulerPair();
    await a.addUpdateContact(Contact(
      publicKey: b.identity.publicKey,
      name: 'b',
      outPathLen: 0,
    ));
    await b.addUpdateContact(Contact(
      publicKey: a.identity.publicKey,
      name: 'a',
      outPathLen: 0,
    ));
    b.prefs.multiAcks = 1;
    scheduler.resetJobs(); // isolate ACK schedules from battery periodic work
    final direct = await _encryptedTextPacket(
      from: a.identity,
      to: b.identity,
      timestamp: 7300,
      txtType: txtTypePlain,
      text: 'cancel ack',
    );
    bLink.deliver(6.0, -70, direct.writeTo());
    await pump();
    expect(scheduler.pending, 2);
    b.stop();
    expect(scheduler.pending, 0);
    scheduler.advance(const Duration(milliseconds: 600));
    await pump();
    expect(bLink.transmitted, isEmpty);
    expect(
      bLink.calls.where((c) =>
          c == 'setRadioParams' ||
          c == 'setTxPower' ||
          c == 'setTuningParams' ||
          c == 'setPathHashMode'),
      isEmpty,
    );
    a.stop();

    final (a2, b2, _, b2Link, scheduler2) = await _schedulerPair();
    await a2.addUpdateContact(Contact(
      publicKey: b2.identity.publicKey,
      name: 'b',
      outPathLen: 0,
    ));
    await b2.addUpdateContact(Contact(
      publicKey: a2.identity.publicKey,
      name: 'a',
      outPathLen: 0,
    ));
    b2.prefs.multiAcks = 1;
    scheduler2.resetJobs(); // isolate ACK schedules from battery periodic work
    final direct2 = await _encryptedTextPacket(
      from: a2.identity,
      to: b2.identity,
      timestamp: 7400,
      txtType: txtTypePlain,
      text: 'reset ack',
    );
    b2Link.deliver(6.0, -70, direct2.writeTo());
    await pump();
    expect(scheduler2.pending, 2);
    await b2.resetVirtualState();
    expect(scheduler2.pending, 0);
    scheduler2.advance(const Duration(milliseconds: 600));
    await pump();
    expect(b2Link.transmitted, isEmpty);
    a2.stop();
    b2.stop();
  });

  test('unpermitted_cli_is_queued_and_not_executed', () async {
    final (a, b, _, bLink, scheduler) = await _schedulerPair();
    await b.addUpdateContact(Contact(
      publicKey: a.identity.publicKey,
      name: 'a',
      outPathLen: 0,
    ));
    scheduler.resetJobs();
    final command = await _encryptedTextPacket(
      from: a.identity,
      to: b.identity,
      timestamp: 100,
      txtType: txtTypeCliCommand,
      text: 'set name Pwned',
    );
    bLink.deliver(6, -70, command.writeTo());
    await pump();

    expect(b.prefs.nodeName, 'bob');
    final queued = await b.syncNextMessage();
    expect(queued?.txtType, txtTypeCliCommand);
    expect(queued?.text, 'set name Pwned');
    expect(bLink.transmitted, isEmpty);
    expect(bLink.calls, isNot(contains('runCliCommand')));
  });

  test('permitted_set_name_changes_virtual_only_and_replies_cli_data_after600ms',
      () async {
    final (a, b, _, bLink, scheduler) = await _schedulerPair();
    await b.addUpdateContact(Contact(
      publicKey: a.identity.publicKey,
      name: 'a',
      flags: 0x10,
      outPathLen: 0,
    ));
    scheduler.resetJobs();
    final command = await _encryptedTextPacket(
      from: a.identity,
      to: b.identity,
      timestamp: 100,
      txtType: txtTypeCliCommand,
      text: 'AB|set name Remote',
    );
    bLink.deliver(6, -70, command.writeTo());
    await pump();

    expect(b.prefs.nodeName, 'Remote');
    expect(await b.syncNextMessage(), isNull);
    expect(bLink.transmitted, isEmpty);
    scheduler.advance(const Duration(milliseconds: 599));
    await pump();
    expect(bLink.transmitted, isEmpty);
    scheduler.advance(const Duration(milliseconds: 1));
    await pump();
    expect(bLink.transmitted, hasLength(1));
    final reply = Packet.readFrom(bLink.transmitted.single)!;
    expect(reply.payloadType, payloadTypeTxtMsg);
    expect(reply.isRouteDirect, isTrue);
    expect(reply.pathHashCount, 0);
    final secret = await a.identity.sharedSecret(b.identity.publicKey);
    final plain = CryptoUtils.macThenDecrypt(
      secret.sublist(0, 16),
      secret,
      reply.payload.sublist(2),
    );
    final r = BufferReader(plain);
    expect(r.readUInt32Le(), isNot(100));
    final flags = r.readByte();
    expect((flags >> 2) & 0x3F, txtTypeCliData);
    expect(r.readCString(), 'AB|OK');
    expect(
      bLink.calls.where((c) =>
          c == 'runCliCommand' ||
          c == 'setRadioParams' ||
          c == 'setTxPower' ||
          c == 'setTuningParams' ||
          c == 'reboot' ||
          c == 'shutdown'),
      isEmpty,
    );
  });

  test('permission_survives_advert_and_restart', () async {
    final aliceId = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 245);
    final bobId = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 246);
    final store = InMemoryNodeStore();
    final link = FakeDeviceLink();
    await link.connect();
    final bob = MeshNode(identity: bobId, link: link, store: store)..start();
    await bob.load();
    await bob.addUpdateContact(Contact(
      publicKey: aliceId.publicKey,
      name: 'alice',
      flags: 0x10,
      outPathLen: 0,
      lastAdvertTimestamp: 1,
    ));
    final advert = await _makeAdvert(
      aliceId,
      type: advTypeChat,
      name: 'alice newer',
      timestamp: 100,
    );
    link.deliver(6, -70, advert.writeTo());
    await pump();
    expect(bob.contacts.single.flags, 0x10);
    expect(bob.contacts.single.name, 'alice newer');

    final restarted = MeshNode(
      identity: bobId,
      link: FakeDeviceLink(),
      store: store,
    );
    await restarted.load();
    expect(restarted.contacts.single.flags, 0x10);
    expect(restarted.contacts.single.name, 'alice newer');
    bob.stop();
  });

  test('remote_radio_reboot_wifi_password_are_denied_no_device_calls', () async {
    final (a, b, _, bLink, scheduler) = await _schedulerPair();
    await b.addUpdateContact(Contact(
      publicKey: a.identity.publicKey,
      name: 'a',
      flags: 0x10,
      outPathLen: 0,
    ));
    scheduler.resetJobs();
    final commands = [
      'set radio 915,250,10,5',
      'reboot',
      'poweroff',
      'get wifi.pwd',
      'set wifi.pwd secret',
    ];
    for (var i = 0; i < commands.length; i++) {
      final packet = await _encryptedTextPacket(
        from: a.identity,
        to: b.identity,
        timestamp: 200 + i,
        txtType: txtTypeCliCommand,
        text: commands[i],
      );
      bLink.deliver(6, -70, packet.writeTo());
      await pump();
    }
    scheduler.advance(const Duration(milliseconds: 600));
    await pump();

    expect(bLink.transmitted, hasLength(commands.length));
    for (final raw in bLink.transmitted) {
      final reply = Packet.readFrom(raw)!;
      final secret = await a.identity.sharedSecret(b.identity.publicKey);
      final plain = CryptoUtils.macThenDecrypt(
          secret.sublist(0, 16), secret, reply.payload.sublist(2));
      final r = BufferReader(plain);
      r.readUInt32Le();
      expect((r.readByte() >> 2) & 0x3F, txtTypeCliData);
      expect(r.readCString(), 'Error: physical administration disabled');
    }
    expect(
      bLink.calls.where((c) =>
          c == 'runCliCommand' ||
          c == 'setRadioParams' ||
          c == 'setTxPower' ||
          c == 'setTuningParams' ||
          c == 'reboot' ||
          c == 'shutdown'),
      isEmpty,
    );
    expect(b.prefs.nodeName, 'bob');
  });

  test('duplicate_allowed_command_executes_once', () async {
    final (a, b, _, bLink, scheduler) = await _schedulerPair();
    await b.addUpdateContact(Contact(
      publicKey: a.identity.publicKey,
      name: 'a',
      flags: 0x10,
      outPathLen: 0,
    ));
    scheduler.resetJobs();
    final command = await _encryptedTextPacket(
      from: a.identity,
      to: b.identity,
      timestamp: 300,
      txtType: txtTypeCliCommand,
      text: 'set multi.acks 7',
    );
    final bytes = command.writeTo();
    bLink.deliver(6, -70, bytes);
    await pump();
    expect(b.prefs.multiAcks, 7);
    b.prefs.multiAcks = 1;
    bLink.deliver(6, -70, bytes);
    await pump();
    expect(b.prefs.multiAcks, 1);
    scheduler.advance(const Duration(milliseconds: 600));
    await pump();
    expect(bLink.transmitted, hasLength(1));
  });

  test('wrong_mac_unknown_sender_hash_collision_cannot_borrow_permission',
      () async {
    final (a, b, _, bLink, scheduler) = await _schedulerPair();
    final target = a.identity.publicKey[0];
    final evil = await _identityWithHashByte(target, 500);
    final attacker = await _identityWithHashByte(target, 900);
    await b.addUpdateContact(Contact(
      publicKey: evil.publicKey,
      name: 'evil',
      flags: 0,
      outPathLen: 0,
    ));
    await b.addUpdateContact(Contact(
      publicKey: a.identity.publicKey,
      name: 'a',
      flags: 0x10,
      outPathLen: 0,
    ));
    scheduler.resetJobs();

    // The attacker has the same 1-byte source hash as the permitted contact
    // but a different shared secret, so every MAC attempt must fail.
    final forged = await _encryptedTextPacket(
      from: attacker,
      to: b.identity,
      timestamp: 400,
      txtType: txtTypeCliCommand,
      text: 'set name Hacked',
    );
    bLink.deliver(6, -70, forged.writeTo());
    await pump();
    expect(b.prefs.nodeName, 'bob');
    expect(await b.syncNextMessage(), isNull);
    expect(bLink.transmitted, isEmpty);

    // A valid packet from the second colliding contact must still decrypt and
    // execute after the first candidate's MAC fails.
    final valid = await _encryptedTextPacket(
      from: a.identity,
      to: b.identity,
      timestamp: 401,
      txtType: txtTypeCliCommand,
      text: 'set name Collision OK',
    );
    bLink.deliver(6, -70, valid.writeTo());
    await pump();
    expect(b.prefs.nodeName, 'Collision OK');
    scheduler.advance(const Duration(milliseconds: 600));
    await pump();
    expect(bLink.transmitted, hasLength(1));
  });

  test('reply_uses_virtual_identity_and_different_timestamp_no_ack', () async {
    final aliceId = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 247);
    final bobId = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 248);
    final link = FakeDeviceLink();
    await link.connect();
    final scheduler = _FakeScheduler();
    final clock = VirtualClock(
      hostWallClock: () => DateTime.fromMillisecondsSinceEpoch(1000 * 1000),
      monotonicClock: () => Duration.zero,
    );
    final bob = MeshNode(
      identity: bobId,
      link: link,
      scheduler: scheduler,
      clock: clock,
    )..start();
    await bob.addUpdateContact(Contact(
      publicKey: aliceId.publicKey,
      name: 'a',
      flags: 0x10,
      outPathLen: 0,
    ));
    scheduler.resetJobs();
    final command = await _encryptedTextPacket(
      from: aliceId,
      to: bobId,
      timestamp: 1000,
      txtType: txtTypeCliCommand,
      text: 'get name',
    );
    link.deliver(6, -70, command.writeTo());
    await pump();
    scheduler.advance(const Duration(milliseconds: 600));
    await pump();
    final reply = Packet.readFrom(link.transmitted.single)!;
    expect(reply.payloadType, payloadTypeTxtMsg);
    expect(reply.payload[1], bobId.publicKey[0],
        reason: 'reply source hash is the virtual identity');
    final secret = await aliceId.sharedSecret(bobId.publicKey);
    final plain = CryptoUtils.macThenDecrypt(
        secret.sublist(0, 16), secret, reply.payload.sublist(2));
    final r = BufferReader(plain);
    expect(r.readUInt32Le(), 1001,
        reason: 'reply timestamp differs from the request timestamp');
    expect((r.readByte() >> 2) & 0x3F, txtTypeCliData);
    expect(r.readCString(), '> MeshChameleon');
    expect(link.transmitted.where((raw) {
      final packet = Packet.readFrom(raw);
      return packet?.payloadType == payloadTypeAck ||
          packet?.payloadType == payloadTypeMultipart;
    }), isEmpty);
    bob.stop();
  });

  test('reply_outbound_zero_hop_direct_unknown_path_scoped_flood', () async {
    final (a, b, _, bLink, scheduler) = await _schedulerPair();
    final contact = Contact(
      publicKey: a.identity.publicKey,
      name: 'a',
      flags: 0x10,
      outPathLen: 0,
    );
    await b.addUpdateContact(contact);
    b.setFloodScopeKey(Uint8List.fromList(List.filled(16, 3)));
    scheduler.resetJobs();
    final direct = await _encryptedTextPacket(
      from: a.identity,
      to: b.identity,
      timestamp: 500,
      txtType: txtTypeCliCommand,
      text: 'get name',
    );
    bLink.deliver(6, -70, direct.writeTo());
    await pump();
    scheduler.advance(const Duration(milliseconds: 600));
    await pump();
    final directReply = Packet.readFrom(bLink.transmitted.single)!;
    expect(directReply.isRouteDirect, isTrue);
    expect(directReply.pathHashCount, 0);

    await b.addUpdateContact(Contact(
      publicKey: a.identity.publicKey,
      name: 'a',
      flags: 0x10,
      outPathLen: -1,
    ));
    bLink.transmitted.clear();
    final unknown = await _encryptedTextPacket(
      from: a.identity,
      to: b.identity,
      timestamp: 501,
      txtType: txtTypeCliCommand,
      text: 'get name',
    );
    bLink.deliver(6, -70, unknown.writeTo());
    await pump();
    scheduler.advance(const Duration(milliseconds: 600));
    await pump();
    final floodReply = Packet.readFrom(bLink.transmitted.single)!;
    expect(floodReply.isRouteFlood, isTrue);
    expect(floodReply.routeType, routeTypeTransportFlood,
        reason: 'reply must use the configured scoped flood');
    expect(floodReply.path, isEmpty);
  });

  test('identity_swap_or_reset_cancels_old_scheduled_reply', () async {
    final (a, b, _, bLink, scheduler) = await _schedulerPair();
    await b.addUpdateContact(Contact(
      publicKey: a.identity.publicKey,
      name: 'a',
      flags: 0x10,
      outPathLen: 0,
    ));
    scheduler.resetJobs();
    final first = await _encryptedTextPacket(
      from: a.identity,
      to: b.identity,
      timestamp: 600,
      txtType: txtTypeCliCommand,
      text: 'set name BeforeSwap',
    );
    bLink.deliver(6, -70, first.writeTo());
    await pump();
    await b.replaceIdentity(await LocalIdentity.fromSeed(Uint8List(32)..[0] = 77));
    scheduler.advance(const Duration(milliseconds: 600));
    await pump();
    expect(bLink.transmitted, isEmpty);

    final second = await _encryptedTextPacket(
      from: a.identity,
      to: b.identity,
      timestamp: 601,
      txtType: txtTypeCliCommand,
      text: 'set name BeforeReset',
    );
    bLink.deliver(6, -70, second.writeTo());
    await pump();
    await b.resetVirtualData();
    scheduler.advance(const Duration(milliseconds: 600));
    await pump();
    expect(bLink.transmitted, isEmpty);
  });
}


Future<LocalIdentity> _identityWithHashByte(int byte, int start) async {
  var n = start;
  while (true) {
    final id = await LocalIdentity.fromSeed(_testKey(n++));
    if (id.publicKey[0] == (byte & 0xFF)) return id;
  }
}

/// Build a `PAYLOAD_TYPE_RESPONSE` datagram from [from] to [to] carrying [body]
/// (the responder's already-tagged response payload).
Future<Packet> _responsePacket(
    MeshNode from, MeshNode to, Uint8List body) async {
  final secret = await from.identity.sharedSecret(to.identity.publicKey);
  final cipher = CryptoUtils.encryptThenMac(secret.sublist(0, 16), secret, body);
  final payload = Uint8List.fromList([
    to.identity.publicKey[0],
    from.identity.publicKey[0],
    ...cipher,
  ]);
  return Packet()
    ..header = Packet.createHeader(payloadTypeResponse, routeTypeDirect)
    ..payload = payload;
}

/// Build a flooded `PAYLOAD_TYPE_GRP_DATA` packet directly (bypassing the
/// 165-byte TX validator) so receive-side limits can be exercised.
Uint8List _groupDataPacket(
    Channel channel, int dataType, Uint8List data) {
  final secret = Uint8List(32);
  secret.setRange(0, channel.secret.length.clamp(0, 32), channel.secret);
  final channelHash = CryptoUtils.sha256(secret.sublist(0, 16))[0];
  final plaintext = BufferWriter()
    ..writeUInt16Le(dataType)
    ..writeByte(data.length)
    ..writeBytes(data);
  final cipher = CryptoUtils.encryptThenMac(
      secret.sublist(0, 16), secret, plaintext.toBytes());
  return (Packet()
        ..header = Packet.createHeader(payloadTypeGrpData, routeTypeFlood)
        ..pathLenByte = 0
        ..payload = Uint8List.fromList([channelHash, ...cipher]))
      .writeTo();
}

extension<T> on T {
  void let(void Function(T) f) => f(this);
}

Uint8List _testKey(int value) {
  final key = Uint8List(32);
  key[0] = value & 0xFF;
  key[1] = (value >> 8) & 0xFF;
  return key;
}

Future<Packet> _makeAdvert(
  LocalIdentity identity, {
  required int type,
  required String name,
  required int timestamp,
  double lat = 0,
  double lon = 0,
  int hashSize = 1,
  int hops = 0,
}) async {
  final packet = await PacketBuilder.createAdvert(
    identity: identity,
    name: name,
    lat: lat,
    lon: lon,
    flags: type,
    timestamp: timestamp,
  );
  if (hops > 0) {
    final encoded = PathUtils.encodePathLen(hashSize, hops);
    packet
      ..pathLenByte = encoded
      ..path = Uint8List.fromList(
        List<int>.generate(PathUtils.getByteLength(encoded), (i) => i + 1),
      );
  }
  return packet;
}

Future<Packet> _signedAdvert(
  LocalIdentity identity,
  List<int> appdata, {
  required int timestamp,
}) async {
  final pubkey = identity.publicKey;
  final timestampBytes =
      (BufferWriter()..writeUInt32Le(timestamp)).toBytes();
  final body = Uint8List.fromList([...pubkey, ...timestampBytes, ...appdata]);
  final signature = await identity.sign(body);
  return Packet()
    ..header = Packet.createHeader(payloadTypeAdvert, routeTypeFlood)
    ..payload = Uint8List.fromList([
      ...pubkey,
      ...timestampBytes,
      ...signature,
      ...appdata,
    ]);
}

Future<(MeshNode, MeshNode, FakeDeviceLink, FakeDeviceLink, _FakeScheduler)>
    _schedulerPair() async {
  final bus = FakeRadioBus();
  final aliceId = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 240);
  final bobId = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 241);
  final aliceLink = FakeDeviceLink(bus: bus);
  final bobLink = FakeDeviceLink(bus: bus);
  await aliceLink.connect();
  await bobLink.connect();
  final scheduler = _FakeScheduler();
  final alice = MeshNode(
    identity: aliceId,
    link: aliceLink,
    prefs: NodePrefs(nodeName: 'alice'),
    scheduler: scheduler,
  )..start();
  final bob = MeshNode(
    identity: bobId,
    link: bobLink,
    prefs: NodePrefs(nodeName: 'bob'),
    scheduler: scheduler,
  )..start();
  return (alice, bob, aliceLink, bobLink, scheduler);
}

Future<Packet> _encryptedTextPacket({
  required LocalIdentity from,
  required LocalIdentity to,
  required int timestamp,
  required int txtType,
  required String text,
  int attempt = 0,
  int? extendedAttempt,
  bool signed = false,
}) async {
  final secret = await from.sharedSecret(to.publicKey);
  final plaintext = BufferWriter()
    ..writeUInt32Le(timestamp)
    ..writeByte((txtType << 2) | (attempt & 0x03));
  if (signed) {
    plaintext.writeBytes(from.publicKey.sublist(0, 4));
  }
  plaintext
    ..writeString(text)
    ..writeByte(0);
  if (extendedAttempt != null) {
    plaintext.writeByte(extendedAttempt & 0xFF);
  }
  final cipher = CryptoUtils.encryptThenMac(
      secret.sublist(0, 16), secret, plaintext.toBytes());
  return Packet()
    ..header = Packet.createHeader(payloadTypeTxtMsg, routeTypeDirect)
    ..payload = Uint8List.fromList([
      to.publicKey[0],
      from.publicKey[0],
      ...cipher,
    ]);
}

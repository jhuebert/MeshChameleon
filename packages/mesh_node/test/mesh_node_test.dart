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
  final List<Uint8List> newAdverts = [];
  final List<Uint8List> pathUpdated = [];

  @override
  void pushMsgWaiting() => msgWaiting++;

  @override
  void pushSendConfirmed(int ackCrc) => confirmed.add(ackCrc);

  @override
  void pushAdvert(Uint8List pubkey) => adverts.add(pubkey);

  @override
  void pushNewAdvert(Uint8List contactFrame) => newAdverts.add(contactFrame);

  @override
  void pushPathUpdated(Uint8List pubkey) => pathUpdated.add(pubkey);

  @override
  void pushTelemetryResponse(Uint8List pubkeyPrefix6, Uint8List data) {
    telemetry.add([...pubkeyPrefix6, ...data]);
  }

  final List<List<int>> telemetry = [];

  @override
  void pushBinaryResponse(Uint8List pubkeyPrefix6, Uint8List data) {}

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

Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late MeshNode alice;
  late MeshNode bob;
  late RecordingSink aliceSink;
  late RecordingSink bobSink;
  late FakeRadioBus bus;

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
    expect(bobSink.newAdverts.length, 1);
  });

  test('repeated advert from a known contact pushes PUSH_CODE_ADVERT', () async {
    await alice.advertise();
    await pump();
    await alice.advertise();
    await pump();
    expect(bob.contacts.length, 1);
    expect(bobSink.adverts.length, 1);
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
    await pump();

    // Bob queued the message for its client.
    expect(bobSink.msgWaiting, 1);
    final msg = bob.syncNextMessage();
    expect(msg, isNotNull);
    expect(msg!.text, 'hello bob');
    expect(msg.senderKey, alice.identity.publicKey);

    // Alice received the ACK.
    expect(aliceSink.confirmed.length, 1);
    expect(aliceSink.confirmed.first, result.expectedAck);
  });

  test('channel text is delivered on the default channel', () async {
    await alice.sendChannelMessage(0, 'hello channel');
    await pump();
    expect(bobSink.msgWaiting, 1);
    final msg = bob.syncNextMessage();
    expect(msg, isNotNull);
    expect(msg!.isChannel, isTrue);
    expect(msg.text, 'alice: hello channel');
    expect(msg.channelIdx, 0);
  });

  test('syncNextMessage drains and returns null when empty', () async {
    await alice.sendChannelMessage(0, 'one');
    await pump();
    expect(bob.syncNextMessage(), isNotNull);
    expect(bob.syncNextMessage(), isNull);
  });

  test('duplicate direct packets are re-ACKed but queued only once', () async {
    await alice.advertise();
    await bob.advertise();
    await pump();

    final result = await alice.sendTextMessage(bob.identity.publicKey, 'dedup me');
    expect(result.success, isTrue);
    await pump();
    final raw = (alice.link as FakeDeviceLink).transmitted.last;
    expect(bob.syncNextMessage(), isNotNull); // the original delivery

    final bobLink = bob.link as FakeDeviceLink;
    final ackedBefore = bobLink.transmitted.length;
    bobLink.deliver(6.0, -70, raw);
    await pump();
    bobLink.deliver(6.0, -70, raw);
    await pump();

    // Not queued again, but ACKed each time (reliability for retransmits).
    expect(bob.syncNextMessage(), isNull);
    expect(bobLink.transmitted.length - ackedBefore, 2);
  });

  test('duplicate channel packets are queued only once', () async {
    await alice.sendChannelMessage(0, 'dup channel');
    await pump();
    final raw = (alice.link as FakeDeviceLink).transmitted.last;
    expect(bob.syncNextMessage(), isNotNull);

    final bobLink = bob.link as FakeDeviceLink;
    bobLink.deliver(6.0, -70, raw);
    await pump();
    bobLink.deliver(6.0, -70, raw);
    await pump();
    expect(bob.syncNextMessage(), isNull);
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
    alice.addUpdateContact(Contact(
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
    final msg = bob.syncNextMessage();
    expect(msg, isNotNull);
    expect(msg!.isChannel, isTrue);
    expect(msg.channelDataType, 0x1234);
    expect(msg.channelDataPayload, payload);

    // A duplicate transmission is not queued again.
    final raw = (alice.link as FakeDeviceLink).transmitted.last;
    (bob.link as FakeDeviceLink).deliver(6.0, -70, raw);
    await pump();
    expect(bob.syncNextMessage(), isNull);
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

    final msg = bob.syncNextMessage();
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
    await pump();

    final msg = alice.syncNextMessage();
    expect(msg, isNotNull);
    expect(msg!.txtType, txtTypeSigned);
    expect(msg.text, 'signed hi');
    expect(aliceLink.transmitted.length - ackedBefore, 1); // ACK sent
  });

  test('contact table capacity is enforced (overwrite opt-in)', () async {
    final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 9);
    final link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(maxContacts: 2),
    );
    await link.connect();
    final node = MeshNode(
      identity: id,
      link: link,
      deviceInfo: const DeviceInfo(maxContacts: 2),
    )..start();
    addTearDown(node.stop);

    Contact c(int i) =>
        Contact(publicKey: Uint8List(32)..[0] = i, name: 'c$i', lastmod: i);
    expect(node.addUpdateContact(c(1)), isTrue);
    expect(node.addUpdateContact(c(2)), isTrue);
    // Full; overwrite is disabled by default.
    expect(node.addUpdateContact(c(3)), isFalse);
    expect(node.contacts.length, 2);

    // Opt into overwrite-on-full: the oldest non-favourite is replaced.
    node.prefs.autoaddConfig = autoAddOverwriteOldest;
    expect(node.addUpdateContact(c(4)), isTrue);
    expect(node.contacts.length, 2);
    expect(node.getContactByKey(Uint8List(32)..[0] = 1), isNull);
    expect(node.getContactByKey(Uint8List(32)..[0] = 4), isNotNull);
  });

  test('room login includes the sync cursor', () async {
    await alice.advertise();
    await bob.advertise();
    await pump();

    alice.addUpdateContact(Contact(
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
    alice.addUpdateContact(Contact(
      publicKey: bob.identity.publicKey,
      name: 'bob',
      outPath: const [0xAA],
      outPathLen: 1,
    ));
    bob.prefs.multiAcks = 1;

    final bobLink = bob.link as FakeDeviceLink;
    final before = bobLink.transmitted.length;
    final result = await alice.sendTextMessage(bob.identity.publicKey, 'hi');
    expect(result.isFlood, isFalse);
    await pump();

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
    expect(peerSink.newAdverts.length, 1);

    // A direct message must be signable and deliverable too.
    final result =
        await importedNode.sendTextMessage(peer.identity.publicKey, 'hi');
    expect(result.success, isTrue);
    await pump();
    final msg = peer.syncNextMessage();
    expect(msg, isNotNull);
    expect(msg!.text, 'hi');
    expect(msg.senderKey, imported.publicKey);

    importedNode.stop();
    peer.stop();
  });

  test('default flood scope tags flooded sends with transport codes', () async {
    final key = Uint8List.fromList(List.generate(16, (i) => i + 1));
    alice.setDefaultFloodScope('RegionOne', key);

    await alice.advertise();
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
    alice.setDefaultFloodScope('def', def);

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
    alice.reboot();
    await alice.sendChannelMessage(0, 'hi4');
    await pump();
    pkt = await lastPacket();
    expect(pkt.transportCode0,
        CryptoUtils.transportCode(def, pkt.payloadType, pkt.payload));
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

  test('setPathHashMode forwards to the device on fw>=10', () async {
    alice.setPathHashMode(2);
    await pump();
    expect(alice.getPathHashMode(), 2);
    expect((alice.link as FakeDeviceLink).pathHashMode, 2);
  });

  test('zeroAdvertIntervals zeroes device advert intervals on fw>=14', () async {
    final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 5);
    const info = DeviceInfo(firmwareVerCode: 14);
    final link = FakeDeviceLink(deviceInfo_: info);
    await link.connect();
    final node = MeshNode(identity: id, link: link, deviceInfo: info)..start();
    await node.zeroAdvertIntervals();
    expect(link.cliCommands, ['adv_int 0', 'f_adv_int 0']);
    node.stop();
  });

  test('zeroAdvertIntervals is a no-op on older firmware', () async {
    final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 6);
    const info = DeviceInfo(firmwareVerCode: 11);
    final link = FakeDeviceLink(deviceInfo_: info);
    await link.connect();
    final node = MeshNode(identity: id, link: link, deviceInfo: info)..start();
    await node.zeroAdvertIntervals();
    expect(link.cliCommands, isEmpty);
    node.stop();
  });

  test('core stats report uptime and radio stats track the last frame',
      () async {
    await alice.advertise();
    await pump();

    final core = alice.getStats(statsTypeCore);
    expect(core['uptime_secs'], isA<int>());

    final radio = bob.getStats(statsTypeRadio);
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

extension<T> on T {
  void let(void Function(T) f) => f(this);
}

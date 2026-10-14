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
  void pushTelemetryResponse(Uint8List pubkeyPrefix6, Uint8List data) {}

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

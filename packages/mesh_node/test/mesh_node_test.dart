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

extension<T> on T {
  void let(void Function(T) f) => f(this);
}

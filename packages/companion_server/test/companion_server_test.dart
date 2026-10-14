import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

class TestBridge extends CompanionBridge {
  TestBridge(this.identity);

  final LocalIdentity identity;
  final contacts = <Contact>[];
  final channels = <int, Channel>{};

  @override
  Uint8List getPublicKey() => identity.publicKey;

  @override
  NodePrefs getSelfInfo() => NodePrefs(
        nodeName: 'TestProxy',
        frequencyHz: 915000000,
        bandwidthHz: 250000,
        spreadingFactor: 10,
        codingRate: 5,
      );

  @override
  DeviceInfo getDeviceInfo() => const DeviceInfo(maxContacts: 1000, maxChannels: 8);

  @override
  BatteryReading getBatteryAndStorage() =>
      const BatteryReading(millivolts: 3900, storageUsedKb: 5, storageTotalKb: 100);

  @override
  List<Contact> getContacts({int since = 0}) => contacts;

  @override
  Contact? getContactByKey(Uint8List pubkey) {
    for (final c in contacts) {
      if (c.publicKeyHex == bytesToHex(pubkey)) return c;
    }
    return null;
  }

  @override
  Contact? getContactByKeyPrefix(Uint8List prefix) {
    final hex = bytesToHex(prefix);
    for (final c in contacts) {
      if (bytesToHex(c.publicKey.sublist(0, prefix.length)) == hex) return c;
    }
    return null;
  }

  @override
  Channel? getChannel(int index) => channels[index];

  @override
  int get maxChannels => 8;

  @override
  bool setChannel(int index, String name, Uint8List secret) {
    channels[index] = Channel(name: name, secret: secret);
    return true;
  }

  @override
  bool setRadioParams(int freqHz, int bwHz, int sf, int cr) => true;

  @override
  Future<SentResult> sendTextMessage(Uint8List pubkey, String text,
          {int txtType = txtTypePlain, int attempt = 0, bool waitForAck = false}) async =>
      const SentResult(success: true, expectedAck: 0x1234, timeoutMs: 5000);

  @override
  Future<Uint8List> sign(Uint8List message) => identity.sign(message);
}

/// Minimal framed client for tests.
class FramedClient {
  FramedClient(this._socket) {
    _socket.listen((data) {
      for (final f in _codec.ingest(data)) {
        _controller.add(f);
      }
    });
  }

  final Socket _socket;
  final SerialFrameCodec _codec = SerialFrameCodec();
  final _controller = StreamController<Uint8List>.broadcast();
  late final StreamQueue<Uint8List> frames = StreamQueue(_controller.stream);

  void send(List<int> payload) =>
      _socket.add(_codec.encodeFrame(payload, prefix: frameInboundPrefix));

  Future<void> close() async {
    await _controller.close();
    await _socket.close();
  }
}

/// A small StreamQueue so tests can await the next frame.
class StreamQueue<T> {
  StreamQueue(Stream<T> stream) {
    _sub = stream.listen(_add);
  }
  late final StreamSubscription<T> _sub;
  final List<T> _buffer = [];
  final List<Completer<T>> _waiters = [];

  Future<T> next() {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    final c = Completer<T>();
    _waiters.add(c);
    return c.future;
  }

  void _add(T value) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(value);
    } else {
      _buffer.add(value);
    }
  }

  Future<void> cancel() => _sub.cancel();
}

void main() {
  late CompanionServer server;
  late FramedClient client;
  late TestBridge bridge;
  late LocalIdentity identity;

  setUp(() async {
    identity = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 1);
    bridge = TestBridge(identity);
    server = CompanionServer(bridge: bridge, config: const CompanionServerConfig(port: 0));
    await server.start();
    final socket = await Socket.connect('127.0.0.1', server.port!);
    client = FramedClient(socket);
  });

  tearDown(() async {
    await client.close();
    await server.stop();
  });

  test('DEVICE_QUERY returns DEVICE_INFO', () async {
    client.send([cmdDeviceQuery, appProtocolVersion]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeDeviceInfo);
    expect(resp[1], defaultFirmwareVerCode);
    expect(resp[2], 255); // maxContacts / 2, clamped to a byte
    expect(resp[3], 8);
  });

  test('APP_START returns SELF_INFO with the proxy public key', () async {
    client.send([cmdAppStart, appProtocolVersion]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeSelfInfo);
    expect(resp.sublist(4, 36), identity.publicKey);
    final r = BufferReader(resp.sublist(4 + 32 + 8 + 4));
    expect(r.readUInt32Le(), 915000);
  });

  test('GET_BATT_AND_STORAGE returns battery', () async {
    client.send([cmdGetBattAndStorage]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeBattAndStorage);
    expect(BufferReader(resp).readUInt16Le(), isNot(0));
  });

  test('GET_CUSTOM_VARS returns custom vars frame', () async {
    client.send([cmdGetCustomVars]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeCustomVars);
  });

  test('GET_CONTACTS streams start/contact/end', () async {
    bridge.contacts.add(Contact(
      publicKey: Uint8List(32)..[0] = 9,
      name: 'peer',
      advType: advTypeChat,
      lastmod: 100,
    ));
    client.send([cmdGetContacts, 0, 0, 0, 0]);
    expect((await client.frames.next())[0], respCodeContactsStart);
    final contact = await client.frames.next();
    expect(contact[0], respCodeContact);
    expect(contact.sublist(1, 33), bridge.contacts.first.publicKey);
    expect((await client.frames.next())[0], respCodeEndOfContacts);
  });

  test('SET_CHANNEL then GET_CHANNEL round trips', () async {
    final psk = Uint8List.fromList(List.generate(16, (i) => i));
    final w = BufferWriter()
      ..writeByte(cmdSetChannel)
      ..writeByte(3)
      ..writeCString('general', 32)
      ..writeBytes(psk);
    client.send(w.toBytes());
    expect((await client.frames.next())[0], respCodeOk);
    client.send([cmdGetChannel, 3]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeChannelInfo);
    expect(resp[1], 3);
    expect(resp.sublist(34, 50), psk);
  });

  test('SET_RADIO_PARAMS validates and forwards', () async {
    final good = BufferWriter()
      ..writeByte(cmdSetRadioParams)
      ..writeUInt32Le(915000) // kHz
      ..writeUInt32Le(250000)
      ..writeByte(10)
      ..writeByte(5);
    client.send(good.toBytes());
    expect((await client.frames.next())[0], respCodeOk);

    final bad = BufferWriter()
      ..writeByte(cmdSetRadioParams)
      ..writeUInt32Le(915000)
      ..writeUInt32Le(250000)
      ..writeByte(99)
      ..writeByte(5);
    client.send(bad.toBytes());
    final err = await client.frames.next();
    expect(err[0], respCodeErr);
    expect(err[1], errCodeIllegalArg);
  });

  test('SEND_TXT_MSG to known contact returns SENT', () async {
    final pubkey = Uint8List(32)..[0] = 7;
    bridge.contacts.add(Contact(publicKey: pubkey, name: 'peer'));
    final w = BufferWriter()
      ..writeByte(cmdSendTxtMsg)
      ..writeByte(txtTypePlain)
      ..writeByte(0)
      ..writeUInt32Le(0)
      ..writeBytes(pubkey.sublist(0, 6))
      ..writeString('hi')
      ..writeByte(0);
    client.send(w.toBytes());
    final resp = await client.frames.next();
    expect(resp[0], respCodeSent);
    final rr = BufferReader(resp)..skipBytes(2);
    expect(rr.readUInt32Le(), 0x1234);
  });

  test('SYNC_NEXT_MESSAGE with empty queue returns NO_MORE_MESSAGES', () async {
    client.send([cmdSyncNextMessage]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeNoMoreMessages);
  });

  test('SIGN_START/DATA/FINISH returns a 64-byte signature', () async {
    client.send([cmdSignStart]);
    final start = await client.frames.next();
    expect(start[0], respCodeSignStart);
    client.send([cmdSignData, ...utf8Bytes('hello')]);
    expect((await client.frames.next())[0], respCodeOk);
    client.send([cmdSignFinish]);
    final sig = await client.frames.next();
    expect(sig[0], respCodeSignature);
    expect(sig.length, 65);
  });

  test('unsupported command returns ERR', () async {
    client.send([cmdReboot]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeErr);
    expect(resp[1], errCodeUnsupportedCmd);
  });
}

List<int> utf8Bytes(String s) => Uint8List.fromList(s.codeUnits);

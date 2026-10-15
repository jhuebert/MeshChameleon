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

  /// Reply text for `CMD_RUN_CLI_COMMAND`; null models a pre-v14 device.
  String? cliReply;

  @override
  Future<String?> runCliCommand(String command) async => cliReply;

  final customVars = <String, String>{};

  @override
  Map<String, String> getCustomVars() => customVars;

  @override
  bool setCustomVar(String name, String value) {
    if (name.isEmpty || name.contains(':') || value.contains(':')) return false;
    customVars[name] = value;
    return true;
  }

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

  int pathHash = 0;
  TuningParams tuning =
      const TuningParams(rxDelayBaseMs: 0, airtimeFactorMs: 0);

  @override
  int getPathHashMode() => pathHash;

  @override
  void setPathHashMode(int mode) => pathHash = mode;

  @override
  Future<TuningParams> getTuningParams() async => tuning;

  @override
  void setTuningParams(int rxDelayBaseMs, int airtimeFactorMs) {
    tuning = TuningParams(
      rxDelayBaseMs: rxDelayBaseMs,
      airtimeFactorMs: airtimeFactorMs,
    );
  }

  @override
  Future<SentResult> sendTelemetryRequest(Uint8List pubkey,
          {bool wantBase = true,
          bool wantLocation = true,
          bool wantEnvironment = true}) async =>
      const SentResult(
          success: true, isFlood: false, expectedAck: 0x99, timeoutMs: 10000);

  @override
  Future<bool> sendTracePathRaw(
          int tag, int authCode, int flags, Uint8List pathBytes) async =>
      true;

  @override
  Future<SentResult> sendTextMessage(Uint8List pubkey, String text,
          {int txtType = txtTypePlain, int attempt = 0, bool waitForAck = false}) async =>
      const SentResult(success: true, expectedAck: 0x1234, timeoutMs: 5000);

  @override
  Future<SentResult> sendPathDiscoveryReq(Uint8List pubkey) async =>
      const SentResult(
          success: true, isFlood: true, expectedAck: 0, timeoutMs: 5000);

  QueuedMessage? nextMessage;

  @override
  QueuedMessage? syncNextMessage() {
    final msg = nextMessage;
    nextMessage = null;
    return msg;
  }

  @override
  Future<Uint8List> sign(Uint8List message) => identity.sign(message);

  bool connection = false;

  @override
  bool hasConnection(Uint8List pubkey) => connection;

  Uint8List? floodScopeKey;
  bool floodUnscoped = false;
  String defaultScopeName = '';
  Uint8List? defaultScopeKey;
  int reboots = 0;

  @override
  void setFloodScopeKey(Uint8List? key) {
    floodScopeKey = key;
    floodUnscoped = false;
  }

  @override
  void setFloodUnscoped() => floodUnscoped = true;

  @override
  void setDefaultFloodScope(String name, Uint8List? key) {
    defaultScopeName = name;
    defaultScopeKey = key;
  }

  @override
  (String, Uint8List?) getDefaultFloodScope() =>
      (defaultScopeName, defaultScopeKey);

  @override
  void reboot() => reboots++;

  Uint8List? anonPubkey;
  Uint8List? anonData;

  @override
  Future<SentResult> sendAnonReq(Uint8List pubkey, Uint8List data) async {
    anonPubkey = pubkey;
    anonData = data;
    return const SentResult(
        success: true, isFlood: false, expectedAck: 0x4242, timeoutMs: 10000);
  }

  Uint8List? binPubkey;
  Uint8List? binData;

  @override
  Future<SentResult> sendBinaryReq(Uint8List pubkey, Uint8List data) async {
    binPubkey = pubkey;
    binData = data;
    return const SentResult(
        success: true, isFlood: false, expectedAck: 0x5151, timeoutMs: 10000);
  }

  Uint8List? contactBlob;
  Uint8List? exportedFor;
  Uint8List? importedData;
  Uint8List? sharedPubkey;

  @override
  Future<Uint8List?> exportContact(Uint8List? pubkey) async {
    exportedFor = pubkey;
    return contactBlob;
  }

  @override
  Future<bool> importContact(Uint8List data) async {
    importedData = data;
    return true;
  }

  @override
  Future<bool> shareContact(Uint8List pubkey) async {
    sharedPubkey = pubkey;
    return true;
  }

  Uint8List allowedRepeatFreq = Uint8List(0);

  @override
  Future<Uint8List> getAllowedRepeatFreq() async => allowedRepeatFreq;

  Uint8List? rawPayload;
  Uint8List? rawPath;
  int? rawPathLenByte;

  @override
  Future<bool> sendRawData(
      Uint8List payload, Uint8List path, int pathLenByte) async {
    rawPayload = payload;
    rawPath = path;
    rawPathLenByte = pathLenByte;
    return true;
  }

  Packet? rawPacket;
  int? rawPriority;

  @override
  Future<bool> sendRawPacket(Packet packet, int priority) async {
    rawPacket = packet;
    rawPriority = priority;
    return true;
  }
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

  test('SYNC_NEXT_MESSAGE returns a queued direct message (V3)', () async {
    // Select the V3 message layout via DEVICE_QUERY.
    client.send([cmdDeviceQuery, 3]);
    await client.frames.next();

    final sender = Uint8List(32)..[0] = 7;
    bridge.nextMessage = QueuedMessage(
      senderKey: sender,
      txtType: txtTypePlain,
      timestamp: 0x11223344,
      text: 'hello',
      pathLen: 2,
      snr: 4.0,
    );

    client.send([cmdSyncNextMessage]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeContactMsgRecvV3);
    final r = BufferReader(resp)..skipBytes(4); // code, snr, reserved, reserved
    expect(r.readBytes(6), sender.sublist(0, 6));
    expect(r.readByte(), 2); // path length
    expect(r.readByte(), txtTypePlain);
    expect(r.readUInt32Le(), 0x11223344);
    expect(r.readRemainingBytes(), utf8Bytes('hello'));

    // The bridge advances its cursor: the queue is now empty.
    client.send([cmdSyncNextMessage]);
    expect((await client.frames.next())[0], respCodeNoMoreMessages);
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

  test('SET_PATH_HASH_MODE stores and DEVICE_QUERY reflects it', () async {
    client.send([cmdSetPathHashMode, 0, 1]);
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.pathHash, 1);

    client.send([cmdDeviceQuery, appProtocolVersion]);
    final resp = await client.frames.next();
    expect(resp[81] & 0xFF, 1);

    client.send([cmdSetPathHashMode, 0, 3]);
    final err = await client.frames.next();
    expect(err[0], respCodeErr);
    expect(err[1], errCodeIllegalArg);
  });

  test('GET/SET_TUNING_PARAMS round trip', () async {
    final set = BufferWriter()
      ..writeByte(cmdSetTuningParams)
      ..writeUInt32Le(777)
      ..writeUInt32Le(42);
    client.send(set.toBytes());
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.tuning.rxDelayBaseMs, 777);
    expect(bridge.tuning.airtimeFactorMs, 42);

    client.send([cmdGetTuningParams]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeTuningParams);
    final r = BufferReader(resp)..skipBytes(1);
    expect(r.readUInt32Le(), 777);
    expect(r.readUInt32Le(), 42);
  });

  test('SEND_TELEMETRY_REQ returns SENT and later pushes the response', () async {
    final pubkey = Uint8List(32)..[0] = 7;
    bridge.contacts.add(Contact(publicKey: pubkey, name: 'sensor'));
    final w = BufferWriter()
      ..writeByte(cmdSendTelemetryReq)
      ..writeBytes([0, 0, 0])
      ..writeBytes(pubkey);
    client.send(w.toBytes());
    final resp = await client.frames.next();
    expect(resp[0], respCodeSent);
    final r = BufferReader(resp)..skipBytes(2);
    expect(r.readUInt32Le(), 0x99);
  });

  test('RUN_CLI_COMMAND forwards to the bridge and returns its reply', () async {
    bridge.cliReply = 'OK';
    client.send([cmdRunCliCommand, ...'adv_int 0'.codeUnits, 0]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeCliReply);
    expect(String.fromCharCodes(resp.sublist(1)), 'OK');
  });

  test('SEND_TRACE_PATH returns SENT', () async {
    final w = BufferWriter()
      ..writeByte(cmdSendTracePath)
      ..writeUInt32Le(0x1234)
      ..writeUInt32Le(0)
      ..writeByte(0)
      ..writeBytes([1, 2, 3]);
    client.send(w.toBytes());
    final resp = await client.frames.next();
    expect(resp[0], respCodeSent);
    final r = BufferReader(resp)..skipBytes(2);
    expect(r.readUInt32Le(), 0x1234);
  });

  test('pushTraceData emits PUSH_CODE_TRACE_DATA matching the firmware',
      () async {
    server.pushTraceData(
      2,
      0,
      0x1111,
      0,
      Uint8List.fromList([1, 2]),
      Uint8List.fromList([0x20, 0x30]),
      24,
    );
    final resp = await client.frames.next();
    expect(resp[0], pushCodeTraceData);
    expect(resp[1], 0);
    expect(resp[2], 2); // path_len
    expect(resp[3], 0); // flags
    final r = BufferReader(resp)..skipBytes(4);
    expect(r.readUInt32Le(), 0x1111);
    expect(r.readUInt32Le(), 0);
    expect(r.readBytes(2), [1, 2]);
    expect(r.readBytes(2), [0x20, 0x30]);
    expect(r.readByte(), 24);
  });

  test('HAS_CONNECTION reflects the bridge session state', () async {
    final pubkey = identity.publicKey;

    bridge.connection = false;
    client.send([cmdHasConnection, ...pubkey]);
    final missing = await client.frames.next();
    expect(missing[0], respCodeErr);
    expect(missing[1], errCodeNotFound);

    bridge.connection = true;
    client.send([cmdHasConnection, ...pubkey]);
    expect((await client.frames.next())[0], respCodeOk);

    // Too short is an illegal argument, not a not-found.
    client.send([cmdHasConnection, 1, 2, 3]);
    final short = await client.frames.next();
    expect(short[0], respCodeErr);
    expect(short[1], errCodeIllegalArg);
  });

  test('sensitive commands respond DISABLED without side effects', () async {
    final privateKey = Uint8List(64);
    final disabledCommands = <List<int>>[
      (BufferWriter()
            ..writeByte(cmdSetDevicePin)
            ..writeUInt32Le(123456))
          .toBytes(),
      [cmdFactoryReset, ...'reset'.codeUnits],
      [cmdExportPrivateKey],
      [cmdImportPrivateKey, ...privateKey],
    ];

    for (final command in disabledCommands) {
      client.send(command);
      expect(await client.frames.next(), [respCodeDisabled]);
    }
  });

  test('SET_FLOOD_SCOPE stores, resets, and forces unscoped', () async {
    final key = Uint8List.fromList(List.generate(16, (i) => i + 1));
    client.send([cmdSetFloodScope, 0, ...key]);
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.floodScopeKey, key);
    expect(bridge.floodUnscoped, isFalse);

    client.send([cmdSetFloodScope, 0]); // reset override
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.floodScopeKey, isNull);

    client.send([cmdSetFloodScope, 1]); // force unscoped (fw v12+)
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.floodUnscoped, isTrue);
  });

  test('SET/GET_DEFAULT_FLOOD_SCOPE round trips and clears', () async {
    final key = Uint8List.fromList(List.generate(16, (i) => (i * 5) % 256));
    final w = BufferWriter()
      ..writeByte(cmdSetDefaultFloodScope)
      ..writeCString('RegionOne', 31)
      ..writeBytes(key);
    client.send(w.toBytes());
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.defaultScopeName, 'RegionOne');
    expect(bridge.defaultScopeKey, key);

    client.send([cmdGetDefaultFloodScope]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeDefaultFloodScope);
    // Name occupies a fixed 31-byte, NUL-padded field, then the 16-byte key.
    expect(resp.sublist(1, 1 + 31).indexOf(0), 'RegionOne'.length);
    expect(resp.sublist(1 + 31, 1 + 31 + 16), key);

    client.send([cmdSetDefaultFloodScope]); // clear
    expect((await client.frames.next())[0], respCodeOk);
    client.send([cmdGetDefaultFloodScope]);
    expect(await client.frames.next(), [respCodeDefaultFloodScope]);
  });

  test('REBOOT accepts the "reboot" magic and calls the bridge', () async {
    client.send([cmdReboot, ...'reboot'.codeUnits]);
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.reboots, 1);

    client.send([cmdReboot, ...'nope'.codeUnits]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeErr);
    expect(resp[1], errCodeIllegalArg);
  });

  test('SEND_ANON_REQ returns SENT and forwards to the bridge', () async {
    final pubkey = identity.publicKey;
    client.send([cmdSendAnonReq, ...pubkey, 1, 0, 7]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeSent);
    expect(bridge.anonPubkey, pubkey);
    expect(bridge.anonData, [1, 0, 7]);
    final r = BufferReader(resp)..skipBytes(2);
    expect(r.readUInt32Le(), 0x4242);
  });

  test('pushBinaryResponse emits reserved + tag + payload', () async {
    bridge.pushSink!.pushBinaryResponse(0x11223344, Uint8List.fromList([9, 8]));
    final resp = await client.frames.next();
    expect(resp[0], pushCodeBinaryResponse);
    expect(resp[1], 0); // reserved
    final r = BufferReader(resp)..skipBytes(2);
    expect(r.readUInt32Le(), 0x11223344);
    expect(r.readRemainingBytes(), [9, 8]);
  });

  test('EXPORT_CONTACT returns the advert blob', () async {
    bridge.contactBlob = Uint8List.fromList([0x04, 1, 2, 3]);
    client.send([cmdExportContact]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeExportContact);
    expect(resp.sublist(1), [0x04, 1, 2, 3]);
    expect(bridge.exportedFor, isNull);

    final pubkey = identity.publicKey;
    client.send([cmdExportContact, ...pubkey]);
    await client.frames.next();
    expect(bridge.exportedFor, pubkey);

    bridge.contactBlob = null;
    client.send([cmdExportContact, ...pubkey]);
    final err = await client.frames.next();
    expect(err[0], respCodeErr);
    expect(err[1], errCodeNotFound);
  });

  test('IMPORT_CONTACT forwards the blob', () async {
    client.send([cmdImportContact, 0x04, 7, 8, 9]);
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.importedData, [0x04, 7, 8, 9]);
  });

  test('SHARE_CONTACT forwards the pubkey', () async {
    final pubkey = identity.publicKey;
    client.send([cmdShareContact, ...pubkey]);
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.sharedPubkey, pubkey);

    client.send([cmdShareContact, 1, 2, 3]);
    final err = await client.frames.next();
    expect(err[0], respCodeErr);
    expect(err[1], errCodeIllegalArg);
  });

  test('GET_ALLOWED_REPEAT_FREQ returns the bridge ranges', () async {
    bridge.allowedRepeatFreq = Uint8List.fromList([0x40, 0x42, 0x0F, 0x00, 0, 0, 0, 0]);
    client.send([cmdGetAllowedRepeatFreq]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeAllowedRepeatFreq);
    expect(resp.sublist(1), bridge.allowedRepeatFreq);
  });

  test('SEND_RAW_DATA forwards the path and payload', () async {
    // path_len 0x02 => 1-byte hashes, 2 hops, then 2 path bytes, 4-byte payload.
    client.send([cmdSendRawData, 0x02, 0xAA, 0xBB, 1, 2, 3, 4]);
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.rawPathLenByte, 0x02);
    expect(bridge.rawPath, [0xAA, 0xBB]);
    expect(bridge.rawPayload, [1, 2, 3, 4]);

    // Too-short payload is rejected.
    client.send([cmdSendRawData, 0x00, 1, 2]);
    final err = await client.frames.next();
    expect(err[0], respCodeErr);
    expect(err[1], errCodeIllegalArg);

    // Reserved hash width (hash_size == 4) is unsupported.
    client.send([cmdSendRawData, 0xC0, 1, 2, 3, 4]);
    final err2 = await client.frames.next();
    expect(err2[0], respCodeErr);
    expect(err2[1], errCodeUnsupportedCmd);
  });

  test('SEND_RAW_PACKET parses and forwards the packet verbatim', () async {
    final packet = Packet()
      ..header = Packet.createHeader(payloadTypeTxtMsg, routeTypeDirect)
      ..payload = Uint8List.fromList([1, 2, 3, 4]);
    packet.setPath([0xAA, 0xBB]);

    client.send([cmdSendRawPacket, 7, ...packet.writeTo()]);
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.rawPriority, 7);
    expect(bridge.rawPacket!.writeTo(), packet.writeTo());

    // Malformed packet bytes are rejected.
    client.send([cmdSendRawPacket, 0, 0xFF, 0xFF]);
    final err = await client.frames.next();
    expect(err[0], respCodeErr);
    expect(err[1], errCodeIllegalArg);
  });

  test('self telemetry returns PUSH_CODE_TELEMETRY_RESPONSE', () async {
    client.send([cmdSendTelemetryReq, 0, 0, 0]);
    final resp = await client.frames.next();
    expect(resp[0], pushCodeTelemetryResponse);
    expect(resp.sublist(2, 8), identity.publicKey.sublist(0, 6));
    expect(resp[8], telemChannelSelf); // CayenneLPP self channel
    expect(resp[9], 0x74); // voltage
  });

  test('RUN_CLI_COMMAND returns ERR when unsupported (fw < 14)', () async {
    bridge.cliReply = null;
    client.send([cmdRunCliCommand, ...utf8Bytes('ver')]);
    expect((await client.frames.next())[0], respCodeErr);
  });

  test('SET/GET_CUSTOM_VAR round-trips', () async {
    client.send([cmdSetCustomVar, ...utf8Bytes('region:us')]);
    expect((await client.frames.next())[0], respCodeOk);
    client.send([cmdGetCustomVars]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeCustomVars);
    expect(String.fromCharCodes(resp.sublist(1)), 'region:us');
  });

  test('a full meshcore-open-style session stays framed and ordered', () async {
    final pubkey = identity.publicKey;
    final peerKey = Uint8List(32)..[0] = 9;
    bridge.contacts.add(Contact(
      publicKey: peerKey,
      name: 'peer',
      advType: advTypeChat,
      lastmod: 100,
    ));
    bridge.contactBlob = Uint8List.fromList([0x04, 0xAA, 0xBB, 0xCC]);

    // Handshake / info block.
    client.send([cmdDeviceQuery, appProtocolVersion]);
    expect((await client.frames.next())[0], respCodeDeviceInfo);

    client.send([cmdAppStart, appProtocolVersion]);
    expect((await client.frames.next())[0], respCodeSelfInfo);

    client.send([cmdGetBattAndStorage]);
    expect((await client.frames.next())[0], respCodeBattAndStorage);

    client.send([cmdGetCustomVars]);
    expect((await client.frames.next())[0], respCodeCustomVars);

    client.send([cmdGetAutoAddConfig]);
    expect((await client.frames.next())[0], respCodeAutoAddConfig);

    client.send([cmdGetContacts, 0, 0, 0, 0]);
    expect((await client.frames.next())[0], respCodeContactsStart);
    expect((await client.frames.next())[0], respCodeContact);
    expect((await client.frames.next())[0], respCodeEndOfContacts);

    // Channel setup round-trips on the same connection.
    final psk = Uint8List.fromList(List.generate(16, (i) => i));
    client.send((BufferWriter()
          ..writeByte(cmdSetChannel)
          ..writeByte(1)
          ..writeCString('general', 32)
          ..writeBytes(psk))
        .toBytes());
    expect((await client.frames.next())[0], respCodeOk);
    client.send([cmdGetChannel, 1]);
    final chan = await client.frames.next();
    expect(chan[0], respCodeChannelInfo);
    expect(chan.sublist(34, 50), psk);

    // Device time + radio params.
    client.send([cmdGetDeviceTime]);
    expect((await client.frames.next())[0], respCodeCurrTime);

    client.send((BufferWriter()
          ..writeByte(cmdSetRadioParams)
          ..writeUInt32Le(915000) // kHz on the wire
          ..writeUInt32Le(250000)
          ..writeByte(10)
          ..writeByte(5))
        .toBytes());
    expect((await client.frames.next())[0], respCodeOk);

    // Regulatory ranges.
    bridge.allowedRepeatFreq = Uint8List.fromList([0x40, 0x42, 0x0F, 0x00]);
    client.send([cmdGetAllowedRepeatFreq]);
    final freq = await client.frames.next();
    expect(freq[0], respCodeAllowedRepeatFreq);
    expect(freq.sublist(1), bridge.allowedRepeatFreq);

    // Contact sharing.
    client.send([cmdShareContact, ...pubkey]);
    expect((await client.frames.next())[0], respCodeOk);

    client.send([cmdExportContact, ...pubkey]);
    final exported = await client.frames.next();
    expect(exported[0], respCodeExportContact);
    expect(exported.sublist(1), bridge.contactBlob);

    client.send([cmdImportContact, 0x04, 1, 2, 3]);
    expect((await client.frames.next())[0], respCodeOk);

    // Binary request: SENT now, the reply follows asynchronously by tag.
    client.send([cmdSendBinaryReq, ...pubkey, reqTypeGetStatus]);
    final sent = await client.frames.next();
    expect(sent[0], respCodeSent);
    final binTag = (BufferReader(sent)..skipBytes(2)).readUInt32Le();
    expect(binTag, 0x5151);
    expect(bridge.binData, [reqTypeGetStatus]);

    bridge.pushSink!.pushBinaryResponse(binTag, Uint8List.fromList([7, 8]));
    final push = await client.frames.next();
    expect(push[0], pushCodeBinaryResponse);
    final pr = BufferReader(push)..skipBytes(2);
    expect(pr.readUInt32Le(), binTag);
    expect(pr.readRemainingBytes(), [7, 8]);

    // Anonymous request: SENT only.
    client.send([cmdSendAnonReq, ...pubkey, 1, 0]);
    final anon = await client.frames.next();
    expect(anon[0], respCodeSent);
    expect((BufferReader(anon)..skipBytes(2)).readUInt32Le(), 0x4242);

    // Raw data + raw packet.
    client.send([cmdSendRawData, 0x00, 1, 2, 3, 4]);
    expect((await client.frames.next())[0], respCodeOk);

    final raw = (Packet()
          ..header = Packet.createHeader(payloadTypeTxtMsg, routeTypeDirect)
          ..payload = Uint8List.fromList([1, 2, 3, 4]))
        .writeTo();
    client.send([cmdSendRawPacket, 0, ...raw]);
    expect((await client.frames.next())[0], respCodeOk);

    // Messaging: a direct text send is acknowledged SENT.
    client.send((BufferWriter()
          ..writeByte(cmdSendTxtMsg)
          ..writeByte(txtTypePlain)
          ..writeByte(0)
          ..writeUInt32Le(0)
          ..writeBytes(peerKey.sublist(0, 6))
          ..writeString('hi')
          ..writeByte(0))
        .toBytes());
    expect((await client.frames.next())[0], respCodeSent);

    // Empty message queue.
    client.send([cmdSyncNextMessage]);
    expect((await client.frames.next())[0], respCodeNoMoreMessages);

    // Path discovery is acknowledged SENT.
    client.send([cmdSendPathDiscoveryReq, 0, ...pubkey]);
    expect((await client.frames.next())[0], respCodeSent);

    // Signing handshake returns a 64-byte signature.
    client.send([cmdSignStart]);
    expect((await client.frames.next())[0], respCodeSignStart);
    client.send([cmdSignData, ...utf8Bytes('hello')]);
    expect((await client.frames.next())[0], respCodeOk);
    client.send([cmdSignFinish]);
    final sig = await client.frames.next();
    expect(sig[0], respCodeSignature);
    expect(sig.length, 65);
  });
}

List<int> utf8Bytes(String s) => Uint8List.fromList(s.codeUnits);

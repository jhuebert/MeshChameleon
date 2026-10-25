import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

class TestBridge extends CompanionBridge {
  TestBridge(this.identity);

  LocalIdentity identity;
  final contacts = <Contact>[];
  final channels = <int, Channel>{};
  int? sentChannelIndex;
  String? sentChannelText;

  @override
  Future<bool> sendChannelMessage(int channelIndex, String text) async {
    sentChannelIndex = channelIndex;
    sentChannelText = text;
    return true;
  }

  int? sentChannelDataIndex;
  int? sentChannelDataType;
  Uint8List? sentChannelDataPayload;
  Uint8List? sentChannelDataPath;
  int? sentChannelDataPathLen;

  @override
  Future<bool> sendChannelData(
    int channelIndex,
    int dataType,
    Uint8List payload, {
    List<int>? path,
    int? pathLenEncoded,
  }) async {
    sentChannelDataIndex = channelIndex;
    sentChannelDataType = dataType;
    sentChannelDataPayload = payload;
    sentChannelDataPath = path == null ? null : Uint8List.fromList(path);
    sentChannelDataPathLen = pathLenEncoded;
    return true;
  }

  @override
  Uint8List getPublicKey() => identity.publicKey;

  NodePrefs selfInfo = NodePrefs(
    nodeName: 'TestProxy',
    frequencyHz: 915000000,
    bandwidthHz: 250000,
    spreadingFactor: 10,
    codingRate: 5,
  );

  @override
  NodePrefs getSelfInfo() => selfInfo;

  int autoAddConfig = 0;
  int autoAddMaxHops = 0;

  @override
  int getAutoAddConfig() => autoAddConfig;

  @override
  int getAutoAddMaxHops() => autoAddMaxHops;

  @override
  Future<void> setAutoAddConfig(int flags, int? maxHops) async {
    autoAddConfig = flags & 0xFF;
    if (maxHops != null) autoAddMaxHops = maxHops.clamp(0, 64);
  }

  @override
  Future<void> setOtherParams({
    required int manualAddContacts,
    int? telemetryModes,
    int? advertLocPolicy,
    int? multiAcks,
  }) async {
    selfInfo.manualAddContacts = manualAddContacts & 0xFF;
    if (telemetryModes != null) {
      final raw = telemetryModes & 0xFF;
      selfInfo
        ..telemetryModeBase = raw & 0x03
        ..telemetryModeLocation = (raw >> 2) & 0x03
        ..telemetryModeEnvironment = (raw >> 4) & 0x03;
    }
    if (advertLocPolicy != null) {
      selfInfo.advertLocPolicy = advertLocPolicy & 0xFF;
    }
    if (multiAcks != null) selfInfo.multiAcks = multiAcks & 0xFF;
  }

  @override
  Future<void> setAdvertName(String name) async => selfInfo.nodeName = name;

  @override
  Future<void> setAdvertLatLon(double lat, double lon) async {
    selfInfo
      ..latitude = lat
      ..longitude = lon;
  }

  DeviceInfo deviceInfo = const DeviceInfo(maxContacts: 1000, maxChannels: 8);

  @override
  DeviceInfo getDeviceInfo() => deviceInfo;

  BatteryReading batteryReading = const BatteryReading(
      millivolts: 3900, storageUsedKb: 5, storageTotalKb: 100);
  int batteryReads = 0;

  @override
  Future<BatteryReading> getBatteryAndStorage() async {
    batteryReads++;
    return batteryReading;
  }

  int statsReads = 0;

  @override
  Future<Map<String, Object?>> getStats(int statsType) async {
    statsReads++;
    final battery = await getBatteryAndStorage();
    if (statsType == statsTypeCore) {
      return {
        'battery_mv': battery.millivolts,
        'uptime_secs': 7,
        'errors': 0,
        'queue_len': 0,
      };
    }
    return const {};
  }

  int currentTime = 100;

  @override
  int getTime() => currentTime;

  @override
  bool setTime(int seconds) {
    if (seconds < currentTime) return false;
    currentTime = seconds;
    return true;
  }

  bool? advertisedFlood;

  @override
  Future<bool> advertise({bool flood = false}) async {
    advertisedFlood = flood;
    return true;
  }

  /// Reply text for `CMD_RUN_CLI_COMMAND`; null models a pre-v14 device.
  String? cliReply;

  @override
  Future<String?> runCliCommand(String command) async => cliReply;

  final customVars = <String, String>{};
  final supportedCustomKeys = <String>{};

  @override
  Map<String, String> getCustomVars() => customVars;

  @override
  Future<void> setCustomVar(String name, String value) async {
    if (!supportedCustomKeys.contains(name) ||
        name.isEmpty ||
        name.contains(':') ||
        value.contains(':')) {
      throw const CompanionOperationError(errCodeIllegalArg);
    }
    customVars[name] = value;
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
  Future<void> setChannel(int index, String name, Uint8List secret) async {
    channels[index] = Channel(name: name, secret: secret);
  }

  int? radioFreqHz;
  int? radioBandwidthHz;
  int? radioSf;
  int? radioCr;
  bool? radioClientRepeat;
  Completer<void>? radioAck;
  CompanionOperationError? radioError;

  @override
  Future<void> setRadioParams(
    int freqHz,
    int bwHz,
    int sf,
    int cr, {
    bool? clientRepeat,
  }) async {
    radioFreqHz = freqHz;
    radioBandwidthHz = bwHz;
    radioSf = sf;
    radioCr = cr;
    radioClientRepeat = clientRepeat;
    if (radioError != null) throw radioError!;
    if (radioAck != null) await radioAck!.future;
  }

  int? txPower;
  Completer<void>? txAck;
  CompanionOperationError? txError;

  @override
  Future<void> setTxPower(int dbm) async {
    txPower = dbm;
    if (txError != null) throw txError!;
    if (txAck != null) await txAck!.future;
  }

  Completer<void>? tuningAck;
  CompanionOperationError? tuningError;

  @override
  Future<void> setTuningParams(int rxDelayBaseMs, int airtimeFactorMs) async {
    if (tuningError != null) throw tuningError!;
    if (tuningAck != null) await tuningAck!.future;
    tuning = TuningParams(
      rxDelayBaseMs: rxDelayBaseMs,
      airtimeFactorMs: airtimeFactorMs,
    );
  }

  int pathHash = 0;
  TuningParams tuning =
      const TuningParams(rxDelayBaseMs: 0, airtimeFactorMs: 0);

  @override
  int getPathHashMode() => pathHash;

  @override
  Future<void> setPathHashMode(int mode) async => pathHash = mode;

  CompanionOperationError? tuningGetError;

  @override
  Future<TuningParams> getTuningParams() async {
    if (tuningGetError != null) throw tuningGetError!;
    return tuning;
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
          {int txtType = txtTypePlain,
          int attempt = 0,
          bool waitForAck = false}) async =>
      const SentResult(success: true, expectedAck: 0x1234, timeoutMs: 5000);

  @override
  Future<SentResult> sendPathDiscoveryReq(Uint8List pubkey) async =>
      const SentResult(
          success: true, isFlood: true, expectedAck: 0, timeoutMs: 5000);

  QueuedMessage? nextMessage;

  @override
  Future<QueuedMessage?> syncNextMessage() async {
    final msg = nextMessage;
    nextMessage = null;
    return msg;
  }

  @override
  Future<Uint8List> sign(Uint8List message) => identity.sign(message);

  int identityImports = 0;
  Object? identitySaveError;

  @override
  Future<Uint8List> exportPrivateKey() async => identity.meshcore64;

  @override
  Future<void> importPrivateKey(Uint8List expandedKey) async {
    if (expandedKey.length != 64 ||
        !await LocalIdentity.validateMeshcore64(expandedKey)) {
      throw const CompanionOperationError(errCodeIllegalArg);
    }
    if (identitySaveError != null) {
      throw const CompanionOperationError(errCodeFileIoError);
    }
    identity = await LocalIdentity.fromMeshcore64(expandedKey);
    identityImports++;
  }

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
  Future<void> setDefaultFloodScope(String name, Uint8List? key) async {
    defaultScopeName = name;
    defaultScopeKey = key;
  }

  @override
  (String, Uint8List?) getDefaultFloodScope() =>
      (defaultScopeName, defaultScopeKey);

  @override
  Future<void> reboot() async => reboots++;

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
  final SerialFrameCodec _codec = SerialFrameCodec.bidirectional();
  final _controller = StreamController<Uint8List>.broadcast();
  late final StreamQueue<Uint8List> frames = StreamQueue(_controller.stream);

  void send(List<int> payload) =>
      sendFrame(payload, prefix: frameInboundPrefix);

  void sendFrame(List<int> payload, {required int prefix}) =>
      _socket.add(_codec.encodeFrame(payload, prefix: prefix));

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

  /// Returns `null` when no frame arrives within [timeout], removing the
  /// waiter so a later frame is not consumed by it.
  Future<T?> nextWithin(Duration timeout) async {
    if (_buffer.isNotEmpty) return _buffer.removeAt(0);
    final c = Completer<T>();
    _waiters.add(c);
    try {
      return await c.future.timeout(timeout);
    } on TimeoutException {
      _waiters.remove(c);
      return null;
    }
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
  late List<String> serverLogs;

  setUp(() async {
    identity = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 1);
    bridge = TestBridge(identity);
    serverLogs = <String>[];
    server = CompanionServer(
      bridge: bridge,
      config: const CompanionServerConfig(port: 0),
      onLog: serverLogs.add,
    );
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

  test('server_rejects_outbound_prefix_as_command', () async {
    // An outbound-prefixed frame is not an app command; the next valid inbound
    // command must be the first one handled.
    client.sendFrame([cmdGetDeviceTime], prefix: frameOutboundPrefix);
    client.send([cmdDeviceQuery, appProtocolVersion]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeDeviceInfo);
  });

  test('target_info_bytes_are_wire_representable', () async {
    bridge.deviceInfo = buildVirtualDeviceInfo(
      clientRepeat: 1,
      pathHashMode: 2,
      targetBaseline: true,
    );
    bridge.pathHash = 2;
    client.send([cmdDeviceQuery, appProtocolVersion]);
    final resp = await client.frames.next();

    expect(resp.length, 82);
    expect(resp[1], targetFirmwareVerCode);
    expect(resp[2], 175, reason: 'max_contacts byte is 350 / 2');
    expect(resp[3], 40);
    expect(resp.sublist(4, 8), [0, 0, 0, 0], reason: 'virtual BLE PIN is 0');
    expect(resp.sublist(8, 20), everyElement(0),
        reason: 'no physical build date');

    final manufacturer = resp.sublist(20, 60);
    expect(
      String.fromCharCodes(manufacturer.takeWhile((b) => b != 0)),
      virtualBoardName,
    );
    expect(
      manufacturer.skip(utf8.encode(virtualBoardName).length),
      everyElement(0),
    );

    final version = resp.sublist(60, 80);
    expect(
      String.fromCharCodes(version.takeWhile((b) => b != 0)),
      targetCompatibilityVersion,
    );
    expect(version.skip(utf8.encode(targetCompatibilityVersion).length),
        everyElement(0));
    expect(resp[80], 1, reason: 'physical client repeat');
    expect(resp[81], 2, reason: 'virtual path mode');
    expect(String.fromCharCodes(resp), isNot(contains('Physical')));
  });

  test('SEND_CHANNEL_DATA accepts 165 bytes and rejects 166', () async {
    bridge.channels[0] = Channel(
      name: 'Public',
      secret: Uint8List.fromList(LocalIdentity.defaultPublicChannelSecret),
    );
    final payload = List<int>.filled(165, 0xAB);
    final accepted = BufferWriter()
      ..writeByte(cmdSendChannelData)
      ..writeByte(0)
      ..writeByte(0xFF)
      ..writeUInt16Le(0x1234)
      ..writeBytes(payload);
    client.send(accepted.toBytes());
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.sentChannelDataPayload, payload);

    final rejected = BufferWriter()
      ..writeByte(cmdSendChannelData)
      ..writeByte(0)
      ..writeByte(0xFF)
      ..writeUInt16Le(0x1234)
      ..writeBytes(List<int>.filled(166, 0xCD));
    client.send(rejected.toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
    expect(bridge.sentChannelDataPayload, payload, reason: 'no partial send');
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

  test('R2 battery_storage_exact_bytes_update_on_virtual_growth_and_shrink',
      () async {
    bridge.batteryReading = const BatteryReading(
      millivolts: 3700,
      storageUsedKb: 1,
      storageTotalKb: 4096,
    );
    client.send([cmdGetBattAndStorage]);
    expect(await client.frames.next(), [
      respCodeBattAndStorage,
      0x74, 0x0E, // 3700 mV, little-endian
      0x01, 0x00, 0x00, 0x00,
      0x00, 0x10, 0x00, 0x00, // 4096 KiB
    ]);

    bridge.batteryReading = const BatteryReading(
      millivolts: 3650,
      storageUsedKb: 5,
      storageTotalKb: 4096,
    );
    client.send([cmdGetBattAndStorage]);
    expect(await client.frames.next(), [
      respCodeBattAndStorage,
      0x42, 0x0E, // 3650 mV
      0x05, 0x00, 0x00, 0x00,
      0x00, 0x10, 0x00, 0x00,
    ]);

    bridge.batteryReading = const BatteryReading(
      millivolts: 3650,
      storageUsedKb: 2,
      storageTotalKb: 4096,
    );
    client.send([cmdGetBattAndStorage]);
    expect(await client.frames.next(), [
      respCodeBattAndStorage,
      0x42,
      0x0E,
      0x02,
      0x00,
      0x00,
      0x00,
      0x00,
      0x10,
      0x00,
      0x00,
    ]);
  });

  test('core_stats_and_self_telemetry_use_same_refreshed_voltage', () async {
    bridge
      ..batteryReading = const BatteryReading(
        millivolts: 3700,
        storageUsedKb: 2,
        storageTotalKb: 4096,
      )
      ..batteryReads = 0
      ..statsReads = 0;

    client.send([cmdSendTelemetryReq, 0, 0, 0]);
    final telemetry = await client.frames.next();
    expect(telemetry[0], pushCodeTelemetryResponse);
    expect(telemetry[9], 0x74);
    expect((telemetry[10] << 8) | telemetry[11], 370); // 3700 mV -> 0.01 V

    client.send([cmdGetStats, statsTypeCore]);
    final stats = await client.frames.next();
    expect(stats[0], respCodeStats);
    expect(stats[1], statsTypeCore);
    expect(BufferReader(stats.sublist(2)).readUInt16Le(), 3700);
    expect(bridge.batteryReads, 2);
    expect(bridge.statsReads, 1);
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

  test('unlisted command IDs return ERR unsupported', () async {
    for (final id in [44, 45, 46, 47, 48, 49, 53]) {
      client.send([id]);
      expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);
    }
  });

  test('raw RX frames are forwarded as PUSH_CODE_LOG_RX_DATA', () async {
    final raw = Uint8List.fromList([1, 2, 3, 4]);
    server.pushRawRxData(6.0, -70, raw);
    expect(await client.frames.next(), [pushCodeLogRxData, 24, 186, ...raw]);
  });

  test('raw custom data uses 0x84 with reserved 0xFF', () async {
    final payload = Uint8List.fromList([9, 8, 7]);
    server.pushRawData(6.0, -70, payload);
    expect(await client.frames.next(),
        [pushCodeRawData, 24, 186, 0xFF, ...payload]);
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

  test('SEND_CHANNEL_TXT_MSG skips the client timestamp', () async {
    bridge.channels[0] = Channel(
      name: 'Public',
      secret: Uint8List.fromList(LocalIdentity.defaultPublicChannelSecret),
    );
    final w = BufferWriter()
      ..writeByte(cmdSendChannelTxtMsg)
      ..writeByte(txtTypePlain)
      ..writeByte(0)
      ..writeUInt32Le(0x6AD05965)
      ..writeString('P')
      ..writeByte(0);
    client.send(w.toBytes());

    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.sentChannelIndex, 0);
    expect(bridge.sentChannelText, 'P');
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

  test('radio_set_has_no_ok_or_cache_change_before_device_ack', () async {
    final ack = Completer<void>();
    bridge.radioAck = ack;
    final frame = BufferWriter()
      ..writeByte(cmdSetRadioParams)
      ..writeUInt32Le(869000)
      ..writeUInt32Le(125000)
      ..writeByte(11)
      ..writeByte(5);
    client.send(frame.toBytes());

    expect(
      await client.frames.nextWithin(const Duration(milliseconds: 50)),
      isNull,
      reason: 'no OK before the device acknowledges the write',
    );
    expect(bridge.radioFreqHz, 869000000);

    ack.complete();
    final ok = await client.frames.next();
    expect(ok, [respCodeOk]);
  });

  test('tx_and_tuning_setters_also_await_ack', () async {
    final txAck = Completer<void>();
    bridge.txAck = txAck;
    client.send([cmdSetRadioTxPower, 10]);
    expect(
      await client.frames.nextWithin(const Duration(milliseconds: 50)),
      isNull,
    );
    txAck.complete();
    expect(await client.frames.next(), [respCodeOk]);

    final tuningAck = Completer<void>();
    bridge.tuningAck = tuningAck;
    final w = BufferWriter()
      ..writeByte(cmdSetTuningParams)
      ..writeUInt32Le(100)
      ..writeUInt32Le(200);
    client.send(w.toBytes());
    expect(
      await client.frames.nextWithin(const Duration(milliseconds: 50)),
      isNull,
    );
    tuningAck.complete();
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.tuning.rxDelayBaseMs, 100);
    expect(bridge.tuning.airtimeFactorMs, 200);
  });

  test('device_err6_is_preserved_and_cache_unchanged', () async {
    bridge.radioError = const CompanionOperationError(
      errCodeIllegalArg,
      message: 'device rejected regulatory setting',
    );
    final frame = BufferWriter()
      ..writeByte(cmdSetRadioParams)
      ..writeUInt32Le(869000)
      ..writeUInt32Le(125000)
      ..writeByte(11)
      ..writeByte(5);
    client.send(frame.toBytes());

    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
  });

  test('disconnected_or_timeout_is_err4_and_cache_uncertain_no_write_retry',
      () async {
    bridge.radioError = const CompanionOperationError(
      errCodeBadState,
      message: 'device reply timed out',
      uncertain: true,
    );
    final frame = BufferWriter()
      ..writeByte(cmdSetRadioParams)
      ..writeUInt32Le(869000)
      ..writeUInt32Le(125000)
      ..writeByte(11)
      ..writeByte(5);
    client.send(frame.toBytes());

    expect(await client.frames.next(), [respCodeErr, errCodeBadState]);
  });

  test('explicit_repeat_validated_and_forwarded', () async {
    BufferWriter radioFrame(int repeat) => BufferWriter()
      ..writeByte(cmdSetRadioParams)
      ..writeUInt32Le(869000)
      ..writeUInt32Le(125000)
      ..writeByte(11)
      ..writeByte(5)
      ..writeByte(repeat);

    client.send(radioFrame(1).toBytes());
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.radioClientRepeat, isTrue);

    client.send(radioFrame(0).toBytes());
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.radioClientRepeat, isFalse);

    bridge.radioFreqHz = null;
    client.send(radioFrame(2).toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
    expect(bridge.radioFreqHz, isNull,
        reason: 'invalid repeat is not forwarded');
  });

  test('tuning_get_without_cache_is_err4', () async {
    bridge.tuningGetError = const CompanionOperationError(
      errCodeBadState,
      message: 'no tuning cache',
    );
    client.send([cmdGetTuningParams]);
    expect(await client.frames.next(), [respCodeErr, errCodeBadState]);
  });

  test('evicted_client_completion_never_replies_to_replacement_client',
      () async {
    final ack = Completer<void>();
    bridge.radioAck = ack;
    final frame = BufferWriter()
      ..writeByte(cmdSetRadioParams)
      ..writeUInt32Le(869000)
      ..writeUInt32Le(125000)
      ..writeByte(11)
      ..writeByte(5);
    client.send(frame.toBytes());
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final replacementSocket = await Socket.connect('127.0.0.1', server.port!);
    final replacement = FramedClient(replacementSocket);
    addTearDown(replacement.close);
    replacement.send([cmdDeviceQuery, appProtocolVersion]);

    ack.complete();
    final first = await replacement.frames.next();
    expect(first[0], respCodeDeviceInfo,
        reason: 'old completion must not send OK to the replacement client');
  });

  test('physical_disabled_reply_is_one_byte_disabled', () async {
    bridge.radioError = const CompanionOperationError(15,
        disabled: true, message: 'device disabled the command');
    final frame = BufferWriter()
      ..writeByte(cmdSetRadioParams)
      ..writeUInt32Le(869000)
      ..writeUInt32Le(125000)
      ..writeByte(11)
      ..writeByte(5);
    client.send(frame.toBytes());
    expect(await client.frames.next(), [respCodeDisabled]);
  });

  test('commands_are_serialized_and_pushes_flow_while_awaiting_ack', () async {
    final ack = Completer<void>();
    bridge.radioAck = ack;
    final frame = BufferWriter()
      ..writeByte(cmdSetRadioParams)
      ..writeUInt32Le(869000)
      ..writeUInt32Le(125000)
      ..writeByte(11)
      ..writeByte(5);
    client.send(frame.toBytes());
    client.send([cmdDeviceQuery, appProtocolVersion]);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // Async radio pushes are not blocked by the waiting command.
    server.pushRawRxData(6.0, -70, Uint8List.fromList([1, 2]));
    expect((await client.frames.next())[0], pushCodeLogRxData);

    // The next client command waits for the in-flight config transaction.
    expect(
      await client.frames.nextWithin(const Duration(milliseconds: 50)),
      isNull,
    );

    ack.complete();
    expect(await client.frames.next(), [respCodeOk]);
    expect((await client.frames.next())[0], respCodeDeviceInfo);
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

  test('SYNC_NEXT_MESSAGE preserves the channel path-hash width (V3)',
      () async {
    client.send([cmdDeviceQuery, 3]);
    await client.frames.next();
    bridge.nextMessage = QueuedMessage(
      senderKey: Uint8List(32),
      timestamp: 0x11223344,
      text: 'heard',
      isChannel: true,
      channelIdx: 1,
      pathLen: 0x42,
    );

    client.send([cmdSyncNextMessage]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeChannelMsgRecvV3);
    expect(resp[5], 0x42);
  });

  test('app reset clearSigningBuffer discards partial signing data', () async {
    client.send([cmdSignStart]);
    expect((await client.frames.next())[0], respCodeSignStart);
    client.send([cmdSignData, ...utf8Bytes('stale reset data')]);
    expect((await client.frames.next())[0], respCodeOk);
    server.clearSigningBuffer();
    client.send([cmdSignFinish]);
    final signature = await client.frames.next();
    expect(signature[0], respCodeSignature);
    expect(
      await LocalIdentity.verify(
        Uint8List(0),
        signature.sublist(1),
        bridge.identity.publicKey,
      ),
      isTrue,
    );
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

    // Nonzero reserved byte is rejected without a state change.
    client.send([cmdSetPathHashMode, 1, 2]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
    expect(bridge.pathHash, 1);
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

  test('SEND_TELEMETRY_REQ returns SENT and later pushes the response',
      () async {
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

  test('RUN_CLI_COMMAND forwards to the bridge and returns its reply',
      () async {
    bridge.cliReply = 'OK';
    client.send([cmdRunCliCommand, ...'adv_int 0'.codeUnits, 0]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeCliReply);
    expect(String.fromCharCodes(resp.sublist(1)), 'OK');
  });

  test('RUN_CLI_COMMAND rejects embedded NUL and bounds UTF-8 replies',
      () async {
    client.send([cmdRunCliCommand, ...utf8Bytes('ver'), 0, 0]);
    final invalid = await client.frames.next();
    expect(invalid[0], respCodeCliReply);
    expect(utf8.decode(invalid.sublist(1)), 'Error: illegal argument');

    bridge.cliReply = 'é' * 200;
    client.send([cmdRunCliCommand, ...utf8Bytes('ver')]);
    final long = await client.frames.next();
    expect(long[0], respCodeCliReply);
    expect(long.length, lessThanOrEqualTo(maxCompanionPayloadSize));
    expect(utf8.decode(long.sublist(1)).endsWith('...'), isTrue);
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

  test('no_logs_contain_imported_or_exported_key_hex_or_payload', () async {
    final replacement = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 44);
    client.send([cmdExportPrivateKey]);
    final exported = await client.frames.next();
    expect(exported[0], respCodePrivateKey);
    client.send([cmdImportPrivateKey, ...replacement.meshcore64]);
    expect(await client.frames.next(), [respCodeOk]);

    final logs = serverLogs.join('\n');
    expect(logs, isNot(contains(bytesToHex(identity.meshcore64))));
    expect(logs, isNot(contains(bytesToHex(replacement.meshcore64))));
    expect(logs, isNot(contains(bytesToHex(identity.publicKey))));
    expect(logs, isNot(contains(bytesToHex(replacement.publicKey))));
  });

  test('pin and factory reset remain DISABLED', () async {
    final disabledCommands = <List<int>>[
      (BufferWriter()
            ..writeByte(cmdSetDevicePin)
            ..writeUInt32Le(123456))
          .toBytes(),
      [cmdFactoryReset, ...'reset'.codeUnits],
    ];

    for (final command in disabledCommands) {
      client.send(command);
      expect(await client.frames.next(), [respCodeDisabled]);
    }
  });

  test('virtual key export/import switches signing and clears sign buffer',
      () async {
    final oldIdentity = bridge.identity;
    final newIdentity = await LocalIdentity.generate();

    client.send([cmdExportPrivateKey]);
    final exported = await client.frames.next();
    expect(exported[0], respCodePrivateKey);
    expect(exported.sublist(1), oldIdentity.meshcore64);

    client.send([cmdSignStart]);
    expect((await client.frames.next())[0], respCodeSignStart);
    client.send([cmdSignData, ...utf8Bytes('old signing data')]);
    expect((await client.frames.next())[0], respCodeOk);

    client.send([
      cmdImportPrivateKey,
      ...newIdentity.meshcore64,
      0xAA,
      0xBB, // documented trailing bytes are ignored
    ]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.identity.publicKey, newIdentity.publicKey);
    expect(bridge.identityImports, 1);

    // The previous client's partial sign buffer must not survive the switch.
    client.send([cmdSignFinish]);
    final signature = await client.frames.next();
    expect(signature[0], respCodeSignature);
    expect(
      await LocalIdentity.verify(
        Uint8List(0),
        signature.sublist(1),
        newIdentity.publicKey,
      ),
      isTrue,
    );

    client.send([cmdAppStart, appProtocolVersion]);
    final info = await client.frames.next();
    expect(info.sublist(4, 36), newIdentity.publicKey);

    client.send([cmdExportPrivateKey]);
    final reExported = await client.frames.next();
    expect(reExported.sublist(1), newIdentity.meshcore64);
  });

  test('storage_failure_keeps_old_active_key_and_returns_err5', () async {
    final oldIdentity = bridge.identity;
    final replacement = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 45);
    bridge.identitySaveError = const FileSystemException('write failed');

    client.send([cmdImportPrivateKey, ...replacement.meshcore64]);
    expect(await client.frames.next(), [respCodeErr, errCodeFileIoError]);
    expect(bridge.identity.publicKey, oldIdentity.publicKey);
    expect(bridge.identityImports, 0);

    client.send([cmdExportPrivateKey]);
    final exported = await client.frames.next();
    expect(exported.sublist(1), oldIdentity.meshcore64);
  });

  test('network_import_rejects_short32_prefix00_ff_and_ecdh_invalid_keys',
      () async {
    final oldIdentity = bridge.identity;
    final prefix00 = hexToBytes(
        '904bfc6464fab00f290b0af4281c582995b553cd3183ce295323d62dfacc325af95f5f99de94f6f17e62634498d53c2d0d13c5f39425ce0b298e4cb9a150db7f');
    final prefixFf = hexToBytes(
        '7072e90de6cbc83fc7f634fc9d16f9fbd44a7533fdbd6740edcc4700cd840d795ccb1c02d93bc82cad1bce56544aeeab3ef722891547abe282498e6f452c241d');
    final invalidEcdh = hexToBytes(
        '0137dddb67ad806e5073c8ee561af2980cf721dbde3f7ace16729d4e8fb2613a5ed63e9c3f6ff001ffdd8f93dc4772cb3a5994a23c00184cc1aea33e4ff8b936');
    final badKeys = <Uint8List>[
      Uint8List(32),
      prefix00,
      prefixFf,
      invalidEcdh,
    ];
    for (final key in badKeys) {
      client.send([cmdImportPrivateKey, ...key]);
      final response = await client.frames.next();
      expect(response, [respCodeErr, errCodeIllegalArg]);
      expect(bridge.identity.publicKey, oldIdentity.publicKey);
      expect(bridge.identityImports, 0);
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
    expect(bridge.reboots, 1);

    client.send([cmdReboot, ...'rebootx'.codeUnits]);
    final extra = await client.frames.next();
    expect(extra, [respCodeErr, errCodeIllegalArg]);
    expect(bridge.reboots, 1);
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
    bridge.allowedRepeatFreq =
        Uint8List.fromList([0x40, 0x42, 0x0F, 0x00, 0, 0, 0, 0]);
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

  test('RUN_CLI_COMMAND uses a CLI_REPLY text even for unsupported', () async {
    bridge.cliReply = null;
    client.send([cmdRunCliCommand, ...utf8Bytes('ver')]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeCliReply);
    expect(utf8.decode(resp.sublist(1)), 'Unknown command');
  });

  test('R2 autoadd vectors clamp and preserve max hops', () async {
    client.send([cmdSetAutoAddConfig, 0x06, 0x02]);
    expect(await client.frames.next(), [respCodeOk]);
    client.send([cmdGetAutoAddConfig]);
    expect(await client.frames.next(), [respCodeAutoAddConfig, 0x06, 0x02]);

    client.send([cmdSetAutoAddConfig, 0x10]);
    expect(await client.frames.next(), [respCodeOk]);
    client.send([cmdGetAutoAddConfig]);
    expect(await client.frames.next(), [respCodeAutoAddConfig, 0x10, 0x02]);

    client.send([cmdSetAutoAddConfig, 0x02, 0xFF]);
    expect(await client.frames.next(), [respCodeOk]);
    client.send([cmdGetAutoAddConfig]);
    expect(await client.frames.next(), [respCodeAutoAddConfig, 0x02, 0x40]);
  });

  test('other_params_preserve_all_omitted_fields_and_pack_telemetry', () async {
    client.send([cmdSetOtherParams, 0x01, 0x26, 0x01, 0x02]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.selfInfo.manualAddContacts, 1);
    expect(bridge.selfInfo.telemetryModes, 0x26);
    expect(bridge.selfInfo.advertLocPolicy, 1);
    expect(bridge.selfInfo.multiAcks, 2);

    // Only manual_add is supplied: everything else is preserved.
    client.send([cmdSetOtherParams, 0x00]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.selfInfo.manualAddContacts, 0);
    expect(bridge.selfInfo.telemetryModes, 0x26);
    expect(bridge.selfInfo.advertLocPolicy, 1);
    expect(bridge.selfInfo.multiAcks, 2);

    client.send([cmdSetOtherParams, 0x01, 0x26, 0x01, 0x02]);
    expect(await client.frames.next(), [respCodeOk]);
    client.send([cmdAppStart, appProtocolVersion]);
    final self = await client.frames.next();
    expect(self[0], respCodeSelfInfo);
    expect(self[44], 2); // multiAcks
    expect(self[45], 1); // advert location policy
    expect(self[46], 0x26); // packed telemetry
    expect(self[47], 1); // manual add
  });

  test('names_utf8_byte_limit_and_coordinate_ranges', () async {
    // 31 UTF-8 bytes is accepted, 32 is not.
    client.send([cmdSetAdvertName, ...utf8Bytes('a' * 31)]);
    expect(await client.frames.next(), [respCodeOk]);
    client.send([cmdSetAdvertName, ...utf8Bytes('a' * 32)]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    // A single trailing NUL is accepted; embedded NUL/control input is not.
    client.send([cmdSetAdvertName, ...utf8Bytes('café'), 0]);
    expect(await client.frames.next(), [respCodeOk]);
    client.send([cmdSetAdvertName, ...utf8Bytes('ab'), 0, ...utf8Bytes('cd')]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
    client.send([cmdSetAdvertName, ...utf8Bytes('bad\nname')]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
    client.send([cmdSetAdvertName, 0xFF]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    client.send([cmdAppStart, appProtocolVersion]);
    final self = await client.frames.next();
    expect(self.sublist(58), utf8Bytes('café'));

    client.send((BufferWriter()
          ..writeByte(cmdSetAdvertLatLon)
          ..writeInt32Le(90000000)
          ..writeInt32Le(-180000000))
        .toBytes());
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.selfInfo.latitude, 90.0);
    expect(bridge.selfInfo.longitude, -180.0);

    client.send((BufferWriter()
          ..writeByte(cmdSetAdvertLatLon)
          ..writeInt32Le(90000001)
          ..writeInt32Le(0))
        .toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
    client.send((BufferWriter()
          ..writeByte(cmdSetAdvertLatLon)
          ..writeInt32Le(0)
          ..writeInt32Le(-180000001))
        .toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
  });

  test('ADD_UPDATE_CONTACT validates wire path/name/coordinates', () async {
    final key = Uint8List(32)..[0] = 9;
    Uint8List body({int pathLen = 0, Uint8List? name, int? latMicros}) {
      final w = BufferWriter()
        ..writeBytes(key)
        ..writeByte(advTypeChat)
        ..writeByte(0)
        ..writeByte(pathLen);
      w.writeBytes(Uint8List(64)); // fixed path field
      w.writeBytes(name ?? Uint8List(32)); // fixed name field
      w.writeUInt32Le(0); // last_advert
      if (latMicros != null) {
        w
          ..writeInt32Le(latMicros)
          ..writeInt32Le(0);
      }
      return w.toBytes();
    }

    client.send([cmdAddUpdateContact, ...body()]);
    expect(await client.frames.next(), [respCodeOk]);

    client.send([cmdAddUpdateContact, ...body(pathLen: 0x7F)]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    final tooLongName = Uint8List.fromList(List.filled(32, 'a'.codeUnitAt(0)));
    client.send([cmdAddUpdateContact, ...body(name: tooLongName)]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    client.send([cmdAddUpdateContact, ...body(latMicros: 90000001)]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
  });

  test('default_advert_is_zero_hop_explicit1_is_flood', () async {
    client.send([cmdSendSelfAdvert]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.advertisedFlood, isFalse);

    client.send([cmdSendSelfAdvert, 0]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.advertisedFlood, isFalse);

    client.send([cmdSendSelfAdvert, 1]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.advertisedFlood, isTrue);
  });

  test('contact push layouts are byte exact', () async {
    final key = Uint8List(32)..[0] = 7;
    server.pushContactDeleted(key);
    expect(await client.frames.next(), [pushCodeContactDeleted, ...key]);

    server.pushContactsFull();
    expect(await client.frames.next(), [pushCodeContactsFull]);

    final body = Uint8List(147);
    server.pushNewAdvert(body);
    final frame = await client.frames.next();
    expect(frame, hasLength(148));
    expect(frame[0], pushCodeNewAdvert);
    expect(frame.sublist(1), body);
  });

  test('R2 virtual time rejects backward and accepts forward', () async {
    bridge.currentTime = 100;
    client.send((BufferWriter()
          ..writeByte(cmdSetDeviceTime)
          ..writeUInt32Le(99))
        .toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
    expect(bridge.currentTime, 100);

    client.send((BufferWriter()
          ..writeByte(cmdSetDeviceTime)
          ..writeUInt32Le(101))
        .toBytes());
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.currentTime, 101);

    client.send([cmdGetDeviceTime]);
    expect(await client.frames.next(), [respCodeCurrTime, 101, 0, 0, 0]);
  });

  test('default custom settings empty and unknown SET returns ERR6', () async {
    client.send([cmdGetCustomVars]);
    expect(await client.frames.next(), [respCodeCustomVars]);

    client.send([cmdSetCustomVar, ...utf8Bytes('gps:1')]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
    expect(bridge.customVars, isEmpty);
  });

  test('SET/GET_CUSTOM_VAR round-trips for a provider-supported key', () async {
    bridge.supportedCustomKeys.add('region');
    client.send([cmdSetCustomVar, ...utf8Bytes('region:us')]);
    expect((await client.frames.next())[0], respCodeOk);
    client.send([cmdGetCustomVars]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeCustomVars);
    expect(String.fromCharCodes(resp.sublist(1)), 'region:us');
    bridge.supportedCustomKeys.clear();
    bridge.customVars.clear();
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

List<int> utf8Bytes(String s) => utf8.encode(s);

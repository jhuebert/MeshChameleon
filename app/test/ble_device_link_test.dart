import 'dart:async';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/services/ble_device_link.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeBlePlatform platform;
  var deviceCounter = 0;

  setUpAll(() {
    platform = _FakeBlePlatform();
    FlutterBluePlusPlatform.instance = platform;
  });

  setUp(() {
    platform
      ..reset()
      ..includeNus = true;
    deviceCounter++;
  });

  BleDeviceLink newLink({
    Duration requestTimeout = const Duration(seconds: 1),
    List<String>? logs,
  }) {
    final device = BluetoothDevice.fromId('AA:BB:CC:DD:EE:$deviceCounter');
    return BleDeviceLink(
      device: device,
      requestTimeout: requestTimeout,
      onLog: logs?.add,
    );
  }

  test('display name prefers the advertised name, then platform, then id', () {
    final device = BluetoothDevice.fromId('11:22:33:44:55:66');
    ScanResult result(String advertised) => ScanResult(
          device: device,
          advertisementData: AdvertisementData(
            advName: advertised,
            txPowerLevel: null,
            appearance: null,
            connectable: true,
            manufacturerData: const {},
            serviceData: const {},
            serviceUuids: const [],
          ),
          rssi: -50,
          timeStamp: DateTime.now(),
        );

    expect(bleCompanionDisplayName(result('  MeshCore-nc1 ')), 'MeshCore-nc1');
    expect(bleCompanionDisplayName(result('')), device.remoteId.toString());
  });

  test('connect discovers the NUS service and reports connected', () async {
    final link = newLink();
    await link.connect();
    expect(link.currentState, LinkState.connected);
    expect(platform.writes, isEmpty);
    await link.disconnect();
    expect(link.currentState, LinkState.disconnected);
  });

  test('connect fails cleanly when the NUS service is missing', () async {
    platform.includeNus = false;
    final link = newLink();
    await expectLater(link.connect(), throwsStateError);
    expect(link.currentState, LinkState.disconnected);
  });

  test('device queries parse replies and forward raw RX frames', () async {
    final link = newLink();
    final received = <(double, int, Uint8List)>[];
    link.setRawRxListener((snr, rssi, raw) => received.add((snr, rssi, raw)));
    await link.connect();

    final info = await link.deviceInfo();
    expect(info.firmwareVerCode, targetFirmwareVerCode);
    expect(info.manufacturer, 'Acme');

    final self = await link.selfInfo();
    expect(self.nodeName, 'dev');
    expect(self.radioParams.frequencyHz, 915000000);

    expect((await link.radioParams()).spreadingFactor, 10);
    expect((await link.radioStats()).noiseFloorDbm, -110);
    final tuning = await link.tuningParams();
    expect(tuning.rxDelayBaseMs, 100);
    expect(tuning.airtimeFactorMs, 200);

    final battery = await link.battery();
    expect(battery!.millivolts, 3700);
    expect(battery.storageUsedKb, 2);
    expect(battery.storageTotalKb, 4096);

    expect(await link.runCliCommand('ver'), 'OK');
    expect(await link.getAllowedRepeatFreq(), [1, 2, 3]);

    platform.emitNotification([pushCodeLogRxData, 24, 186, 1, 2, 3]);
    await _flush();
    expect(received.single.$1, 6.0);
    expect(received.single.$2, -70);
    expect(received.single.$3, [1, 2, 3]);

    // Malformed RX frames are ignored.
    platform.emitNotification([pushCodeLogRxData, 0]);
    await _flush();
    expect(received, hasLength(1));
  });

  test('setters accept OK and relay DISABLED replies', () async {
    final link = newLink();
    await link.connect();

    await link.setRadioParams(_params(), clientRepeat: true);
    await link.setTxPower(17);
    await link.setTuningParams(
      const TuningParams(rxDelayBaseMs: 1, airtimeFactorMs: 2),
    );
    await link.setPathHashMode(1);
    await link.sendRawPacket(Uint8List.fromList([1, 2, 3]), 7);
    expect(platform.writes.last[0], cmdSendRawPacket);
    expect(platform.writes.last[1], 7);

    platform.disabled = true;
    await expectLater(
      link.setTxPower(10),
      throwsA(isA<DeviceCommandError>()
          .having((e) => e.kind, 'kind', DeviceCommandErrorKind.disabled)),
    );
  });

  test('lifecycle commands write without awaiting a reply', () async {
    final link = newLink();
    await link.connect();

    await link.reboot();
    expect(platform.writes.last, [cmdReboot, ...'reboot'.codeUnits]);
    await link.shutdown();
    expect(platform.writes.last, [cmdRunCliCommand, ...'poweroff'.codeUnits]);
  });

  test('ERR replies map to device and malformed errors', () async {
    final link = newLink();
    await link.connect();

    platform.errReply = [respCodeErr, errCodeTableFull];
    await expectLater(
      link.deviceInfo(),
      throwsA(isA<DeviceCommandError>()
          .having((e) => e.kind, 'kind', DeviceCommandErrorKind.device)
          .having((e) => e.code, 'code', errCodeTableFull)),
    );

    platform.errReply = [respCodeErr];
    await expectLater(
      link.deviceInfo(),
      throwsA(isA<DeviceCommandError>()
          .having((e) => e.kind, 'kind', DeviceCommandErrorKind.malformed)),
    );
  });

  test('an unexpected reply is ignored until the expected one arrives',
      () async {
    final link = newLink();
    await link.connect();
    platform.extraReply = [respCodeOk];

    final info = await link.deviceInfo();
    expect(info.firmwareVerCode, targetFirmwareVerCode);
  });

  test('a reply that arrives while the write is pending is not lost', () async {
    final link = newLink();
    await link.connect();
    platform.writeGate = Completer<void>();
    platform.errReply = [respCodeErr, errCodeTableFull];

    final request = link.deviceInfo();
    await _flush();
    expect(platform.writes, isNotEmpty,
        reason: 'the reply should be emitted while the write is still pending');
    platform.writeGate!.complete();
    platform.writeGate = null;

    await expectLater(
      request,
      throwsA(isA<DeviceCommandError>()
          .having((e) => e.kind, 'kind', DeviceCommandErrorKind.device)
          .having((e) => e.code, 'code', errCodeTableFull)),
    );
  });

  test('request timeouts surface as timeout errors', () async {
    final link = newLink(requestTimeout: const Duration(milliseconds: 30));
    await link.connect();
    platform.silent = true;

    await expectLater(
      link.deviceInfo(),
      throwsA(isA<DeviceCommandError>()
          .having((e) => e.kind, 'kind', DeviceCommandErrorKind.timeout)),
    );
    expect(link.currentState, LinkState.disconnected);
    await expectLater(
      link.deviceInfo(),
      throwsA(isA<DeviceCommandError>()
          .having((e) => e.kind, 'kind', DeviceCommandErrorKind.disconnected)),
    );
  });

  test('oversized frames are rejected before writing', () async {
    final link = newLink();
    await link.connect();

    await expectLater(
      link.sendRawPacket(Uint8List(maxCompanionPayloadSize)),
      throwsArgumentError,
    );
  });

  test('oversized notifications are logged and dropped', () async {
    final logs = <String>[];
    final link = newLink(logs: logs);
    await link.connect();

    platform.emitNotification(List.filled(maxCompanionPayloadSize + 1, 1));
    await _flush();
    expect(logs, anyElement(contains('dropping oversized BLE frame')));
  });

  test('battery failures are logged and return null', () async {
    final logs = <String>[];
    final link =
        newLink(requestTimeout: const Duration(milliseconds: 30), logs: logs);
    await link.connect();

    platform.silent = true;
    expect(await link.battery(), isNull);
    expect(logs, anyElement(contains('battery read failed')));
  });

  test('a device disconnect fails pending requests and updates state',
      () async {
    final link = newLink();
    await link.connect();

    platform.silent = true;
    final pending = link.deviceInfo();
    await _flush();
    platform.dropConnection();
    await expectLater(
      pending,
      throwsA(isA<DeviceCommandError>()
          .having((e) => e.kind, 'kind', DeviceCommandErrorKind.disconnected)),
    );
    expect(link.currentState, LinkState.disconnected);
  });

  test('operations require a connected link', () async {
    final link = newLink();
    await expectLater(
      link.deviceInfo(),
      throwsA(isA<DeviceCommandError>()
          .having((e) => e.kind, 'kind', DeviceCommandErrorKind.disconnected)),
    );
    await expectLater(link.reboot(), throwsA(isA<DeviceCommandError>()));
    await expectLater(link.shutdown(), throwsA(isA<DeviceCommandError>()));
    expect(await link.battery(), isNull);
  });

  test('reconnect replaces subscriptions without duplicate delivery', () async {
    final link = newLink();
    await link.connect();
    await link.disconnect();
    await link.connect();

    var count = 0;
    link.setRawRxListener((_, __, ___) => count++);
    platform.emitNotification([pushCodeLogRxData, 0, 0, 9]);
    await _flush();
    expect(count, 1);
  });

  test('connect is a no-op when already connected', () async {
    final link = newLink();
    await link.connect();
    await link.connect();
    expect(link.currentState, LinkState.connected);
  });

  test('platform name is used when the advertisement has no name', () async {
    final link = newLink();
    await link.connect();
    final device = BluetoothDevice.fromId('AA:BB:CC:DD:EE:$deviceCounter');
    platform.setPlatformName(device.remoteId, 'platform-name');
    await _flush();

    final result = ScanResult(
      device: device,
      advertisementData: AdvertisementData(
        advName: '',
        txPowerLevel: null,
        appearance: null,
        connectable: true,
        manufacturerData: const {},
        serviceData: const {},
        serviceUuids: const [],
      ),
      rssi: -50,
      timeStamp: DateTime.now(),
    );
    expect(bleCompanionDisplayName(result), 'platform-name');
  });
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(const Duration(milliseconds: 1));
}

RadioParams _params() => const RadioParams(
      frequencyHz: 915000000,
      bandwidthHz: 250000,
      spreadingFactor: 10,
      codingRate: 5,
    );

Uint8List _deviceInfo() => (BufferWriter()
      ..writeByte(respCodeDeviceInfo)
      ..writeByte(targetFirmwareVerCode)
      ..writeByte(255)
      ..writeByte(8)
      ..writeUInt32Le(0)
      ..writeCString('build', 12)
      ..writeCString('Acme', 40)
      ..writeCString('fw 1.0', 20)
      ..writeByte(0)
      ..writeByte(0))
    .toBytes();

Uint8List _selfInfo() => (BufferWriter()
      ..writeByte(respCodeSelfInfo)
      ..writeByte(advTypeChat)
      ..writeByte(20)
      ..writeByte(22)
      ..writeBytes(Uint8List(32)..[0] = 7)
      ..writeInt32Le(0)
      ..writeInt32Le(0)
      ..writeByte(0)
      ..writeByte(0)
      ..writeByte(0)
      ..writeByte(0)
      ..writeUInt32Le(915000)
      ..writeUInt32Le(250000)
      ..writeByte(10)
      ..writeByte(5)
      ..writeCString('dev', 4))
    .toBytes();

Uint8List _radioStats() => (BufferWriter()
      ..writeByte(respCodeStats)
      ..writeByte(statsTypeRadio)
      ..writeUInt16Le(0xFF92)
      ..writeByte(0xC0)
      ..writeByte(24)
      ..writeUInt32Le(1)
      ..writeUInt32Le(2))
    .toBytes();

Uint8List _tuning() => (BufferWriter()
      ..writeByte(respCodeTuningParams)
      ..writeUInt32Le(100)
      ..writeUInt32Le(200))
    .toBytes();

Uint8List _battery() => (BufferWriter()
      ..writeByte(respCodeBattAndStorage)
      ..writeUInt16Le(3700)
      ..writeUInt32Le(2)
      ..writeUInt32Le(4096))
    .toBytes();

base class _FakeBlePlatform extends FlutterBluePlusPlatform {
  final _connections = StreamController<BmConnectionStateResponse>.broadcast();
  final _services = StreamController<BmDiscoverServicesResult>.broadcast();
  final _received = StreamController<BmCharacteristicData>.broadcast();
  final _written = StreamController<BmCharacteristicData>.broadcast();
  final _descriptors = StreamController<BmDescriptorData>.broadcast();
  final _names = StreamController<BmNameChanged>.broadcast();

  final writes = <List<int>>[];
  bool includeNus = true;
  bool disabled = false;
  bool silent = false;
  List<int>? errReply;
  List<int>? extraReply;
  Completer<void>? writeGate;
  DeviceIdentifier? activeRemoteId;

  void reset() {
    writes.clear();
    includeNus = true;
    disabled = false;
    silent = false;
    errReply = null;
    extraReply = null;
    writeGate = null;
  }

  @override
  Stream<BmConnectionStateResponse> get onConnectionStateChanged =>
      _connections.stream;

  @override
  Stream<BmDiscoverServicesResult> get onDiscoveredServices => _services.stream;

  @override
  Stream<BmCharacteristicData> get onCharacteristicReceived => _received.stream;

  @override
  Stream<BmCharacteristicData> get onCharacteristicWritten => _written.stream;

  @override
  Stream<BmDescriptorData> get onDescriptorWritten => _descriptors.stream;

  @override
  Stream<BmNameChanged> get onNameChanged => _names.stream;

  @override
  Future<bool> connect(BmConnectRequest request) async {
    activeRemoteId = request.remoteId;
    scheduleMicrotask(() => _connections.add(BmConnectionStateResponse(
          remoteId: request.remoteId,
          connectionState: BmConnectionStateEnum.connected,
          disconnectReasonCode: null,
          disconnectReasonString: null,
        )));
    return true;
  }

  @override
  Future<bool> disconnect(BmDisconnectRequest request) async {
    activeRemoteId = request.remoteId;
    dropConnection();
    return true;
  }

  void dropConnection() {
    final id = activeRemoteId;
    if (id == null) return;
    _connections.add(BmConnectionStateResponse(
      remoteId: id,
      connectionState: BmConnectionStateEnum.disconnected,
      disconnectReasonCode: null,
      disconnectReasonString: null,
    ));
  }

  @override
  Future<bool> discoverServices(BmDiscoverServicesRequest request) async {
    final characteristics = <BmBluetoothCharacteristic>[
      _characteristic(request.remoteId, MeshCoreUuids.rx, write: true),
      _characteristic(request.remoteId, MeshCoreUuids.tx, notify: true),
    ];
    final services = <BmBluetoothService>[];
    if (includeNus) {
      services.add(BmBluetoothService(
        remoteId: request.remoteId,
        primaryServiceUuid: null,
        serviceUuid: Guid(MeshCoreUuids.service),
        characteristics: characteristics,
      ));
    } else {
      services.add(BmBluetoothService(
        remoteId: request.remoteId,
        primaryServiceUuid: null,
        serviceUuid: Guid('0000180a-0000-1000-8000-00805f9b34fb'),
        characteristics: const [],
      ));
    }
    scheduleMicrotask(() => _services.add(BmDiscoverServicesResult(
          remoteId: request.remoteId,
          services: services,
          success: true,
          errorCode: 0,
          errorString: '',
        )));
    return true;
  }

  BmBluetoothCharacteristic _characteristic(
    DeviceIdentifier remoteId,
    String uuid, {
    bool write = false,
    bool notify = false,
  }) =>
      BmBluetoothCharacteristic(
        remoteId: remoteId,
        primaryServiceUuid: null,
        serviceUuid: Guid(MeshCoreUuids.service),
        characteristicUuid: Guid(uuid),
        instanceId: 0,
        descriptors: const [],
        properties: BmCharacteristicProperties(
          broadcast: false,
          read: false,
          writeWithoutResponse: false,
          write: write,
          notify: notify,
          indicate: false,
          authenticatedSignedWrites: false,
          extendedProperties: false,
          notifyEncryptionRequired: false,
          indicateEncryptionRequired: false,
        ),
      );

  @override
  Future<bool> setNotifyValue(BmSetNotifyValueRequest request) async => false;

  @override
  Future<bool> writeCharacteristic(BmWriteCharacteristicRequest request) async {
    writes.add(List<int>.from(request.value));
    scheduleMicrotask(() {
      _written.add(BmCharacteristicData(
        remoteId: request.remoteId,
        primaryServiceUuid: request.primaryServiceUuid,
        serviceUuid: request.serviceUuid,
        characteristicUuid: request.characteristicUuid,
        instanceId: request.instanceId,
        value: request.value,
        success: true,
        errorCode: 0,
        errorString: '',
      ));
      if (silent) return;
      final extra = extraReply;
      if (extra != null) {
        extraReply = null;
        _emitReply(request.remoteId, extra);
      }
      final reply = errReply ?? _replyFor(request.value);
      if (reply != null) _emitReply(request.remoteId, reply);
    });
    final gate = writeGate;
    if (gate != null) await gate.future;
    return true;
  }

  List<int>? _replyFor(List<int> frame) {
    switch (frame[0]) {
      case cmdDeviceQuery:
        return _deviceInfo();
      case cmdAppStart:
        return _selfInfo();
      case cmdGetStats:
        return _radioStats();
      case cmdGetTuningParams:
        return _tuning();
      case cmdGetBattAndStorage:
        return _battery();
      case cmdRunCliCommand:
        return [respCodeCliReply, ...'OK'.codeUnits];
      case cmdGetAllowedRepeatFreq:
        return [respCodeAllowedRepeatFreq, 1, 2, 3];
      case cmdSetRadioParams:
      case cmdSetRadioTxPower:
      case cmdSetTuningParams:
      case cmdSetPathHashMode:
      case cmdSendRawPacket:
        return [disabled ? respCodeDisabled : respCodeOk];
    }
    return null;
  }

  void _emitReply(DeviceIdentifier remoteId, List<int> payload) {
    _received.add(BmCharacteristicData(
      remoteId: remoteId,
      primaryServiceUuid: null,
      serviceUuid: Guid(MeshCoreUuids.service),
      characteristicUuid: Guid(MeshCoreUuids.tx),
      instanceId: 0,
      value: payload,
      success: true,
      errorCode: 0,
      errorString: '',
    ));
  }

  void emitNotification(List<int> payload) {
    final id = activeRemoteId;
    if (id == null) return;
    _emitReply(id, payload);
  }

  void setPlatformName(DeviceIdentifier remoteId, String name) {
    _names.add(BmNameChanged(remoteId: remoteId, name: name));
  }
}

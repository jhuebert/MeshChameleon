import 'dart:async';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

/// Nordic UART Service UUIDs used by the MeshCore BLE interface.
class MeshCoreUuids {
  static const service = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const rx = '6e400002-b5a3-f393-e0a9-e50e24dcca9e'; // phone -> device
  static const tx = '6e400003-b5a3-f393-e0a9-e50e24dcca9e'; // device -> phone
  static final serviceGuid = Guid(service);

  /// Scan for MeshCore companion devices advertising the NUS service.
  static Stream<List<ScanResult>> scanForDevices() {
    FlutterBluePlus.startScan(
      withServices: [serviceGuid],
      timeout: const Duration(seconds: 15),
    );
    return FlutterBluePlus.scanResults;
  }
}

/// [RadioLink] over BLE (NUS). BLE carries raw frames: one GATT write/notify is
/// one companion frame, with no `'<'`/`'>'` wrapper.
class BleDeviceLink implements RadioLink {
  BleDeviceLink({
    required this.device,
    this.requestTimeout = const Duration(seconds: 5),
    this.onLog,
  });

  final BluetoothDevice device;
  final Duration requestTimeout;
  final void Function(String message)? onLog;

  final _stateController = StreamController<LinkState>.broadcast();
  LinkState _state = LinkState.disconnected;
  BluetoothCharacteristic? _rx;
  BluetoothCharacteristic? _tx;
  StreamSubscription<List<int>>? _notifySub;
  RawRxListener? _rawRxListener;

  Completer<Uint8List>? _pending;
  Set<int> _expected = const {};
  Future<void> _lock = Future<void>.value();

  @override
  Stream<LinkState> get state => _stateController.stream;

  @override
  LinkState get currentState => _state;

  void _setState(LinkState value) {
    _state = value;
    if (!_stateController.isClosed) _stateController.add(value);
  }

  @override
  Future<void> connect() async {
    if (_state == LinkState.connected) return;
    _setState(LinkState.connecting);
    try {
      await device.connect(timeout: const Duration(seconds: 15));
      try {
        await device.requestMtu(185);
      } catch (e) {
        onLog?.call('[BleDeviceLink] requestMtu failed: $e');
      }
      final services = await device.discoverServices();
      final nus = services.firstWhere(
        (s) => s.uuid == MeshCoreUuids.serviceGuid,
        orElse: () => throw StateError('NUS service not found'),
      );
      _rx = nus.characteristics
          .firstWhere((c) => c.uuid == Guid(MeshCoreUuids.rx));
      _tx = nus.characteristics
          .firstWhere((c) => c.uuid == Guid(MeshCoreUuids.tx));
      await _tx!.setNotifyValue(true);
      _notifySub = _tx!.onValueReceived.listen(
        (data) => _onFrame(Uint8List.fromList(data)),
      );
      _setState(LinkState.connected);
    } catch (e) {
      _setState(LinkState.disconnected);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    await _notifySub?.cancel();
    _notifySub = null;
    _failAll(StateError('disconnected'));
    try {
      await device.disconnect();
    } catch (_) {}
    _setState(LinkState.disconnected);
  }

  @override
  void setRawRxListener(RawRxListener? listener) => _rawRxListener = listener;

  void _onFrame(Uint8List frame) {
    if (frame.isEmpty) return;
    if (frame[0] == pushCodeLogRxData) {
      final raw = RawRxFrame.parse(frame);
      if (raw != null) _rawRxListener?.call(raw.snr, raw.rssi, raw.raw);
      return;
    }
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      if (_expected.contains(frame[0])) {
        _pending = null;
        pending.complete(frame);
      } else if (frame[0] == respCodeErr) {
        _pending = null;
        pending.completeError(StateError('device returned error ${frame[1]}'));
      }
    }
  }

  void _failAll(Object error) {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.completeError(error);
  }

  Future<T> _runExclusive<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _lock = _lock.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  Future<Uint8List> _request(Uint8List frame, Set<int> expected) {
    return _runExclusive(() async {
      final rx = _rx;
      if (rx == null) throw StateError('BLE not connected');
      if (_pending != null) throw StateError('request already in flight');
      final completer = Completer<Uint8List>();
      _pending = completer;
      _expected = expected;
      try {
        await rx.write(frame, withoutResponse: false);
        return await completer.future.timeout(requestTimeout);
      } finally {
        _pending = null;
      }
    });
  }

  @override
  Future<void> sendRawPacket(Uint8List packet, [int priority = 0]) async {
    final rx = _rx;
    if (rx == null) throw StateError('BLE not connected');
    await rx.write(DeviceFrames.sendRawPacket(packet, priority), withoutResponse: false);
  }

  @override
  Future<DeviceInfo> deviceInfo() async {
    final frame =
        await _request(DeviceFrames.deviceQuery(), {respCodeDeviceInfo, respCodeErr});
    return TcpDeviceLink.parseDeviceInfo(frame);
  }

  @override
  Future<RadioParams> radioParams() async {
    final frame =
        await _request(DeviceFrames.appStart(), {respCodeSelfInfo, respCodeErr});
    final info = ParsedSelfInfo.parse(frame);
    if (info == null) throw StateError('invalid SELF_INFO from device');
    return info.radioParams;
  }

  @override
  Future<void> setRadioParams(RadioParams params) async {
    await _request(DeviceFrames.setRadioParams(params), {respCodeOk, respCodeErr});
  }

  @override
  Future<void> setTxPower(int dbm) async {
    await _request(DeviceFrames.setTxPower(dbm), {respCodeOk, respCodeErr});
  }

  @override
  Future<BatteryReading?> battery() async {
    try {
      final frame = await _request(
        DeviceFrames.getBattAndStorage(),
        {respCodeBattAndStorage, respCodeErr},
      );
      final r = BufferReader(frame)..skipBytes(1);
      return BatteryReading(
        millivolts: r.readUInt16Le(),
        storageUsedKb: r.readUInt32Le(),
        storageTotalKb: r.readUInt32Le(),
      );
    } catch (e) {
      onLog?.call('[BleDeviceLink] battery read failed: $e');
      return null;
    }
  }
}

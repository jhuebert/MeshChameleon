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

  /// Results from the active MeshCore companion scan.
  static Stream<List<ScanResult>> get scanResults => FlutterBluePlus.scanResults;

  /// Start scanning for MeshCore companion devices advertising the NUS service.
  static Future<void> startScan() => FlutterBluePlus.startScan(
        withServices: [serviceGuid],
        timeout: const Duration(seconds: 15),
      );
}

/// The user-facing name from a scan result.
///
/// Android can return a stale, MAC-derived name from
/// [BluetoothDevice.platformName] after a device has changed its GAP name.
/// The current name in the advertisement is authoritative; use the platform
/// name only when the advertisement has no name.
String bleCompanionDisplayName(ScanResult result) {
  final advertised = result.advertisementData.advName.trim();
  if (advertised.isNotEmpty) return advertised;
  final platformName = result.device.platformName.trim();
  return platformName.isNotEmpty
      ? platformName
      : result.device.remoteId.toString();
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
  StreamSubscription<BluetoothConnectionState>? _connSub;
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
    if (_state == LinkState.connected || _state == LinkState.connecting) {
      return;
    }
    // A prior connection's platform-wide streams are not tied to the old
    // characteristic object. Cancel them before subscribing again or every
    // notification is delivered once per reconnect.
    await _cancelSubscriptions();
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
      // Surface an unexpected drop (e.g. the device rebooting) so the app's
      // link watcher can reconnect.
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected &&
            _state == LinkState.connected) {
          onLog?.call('[BleDeviceLink] device disconnected');
          _failAll(const DeviceCommandError.disconnected(
              message: 'BLE disconnected'));
          _cancelNotifySubscription();
          _setState(LinkState.disconnected);
        }
      });
      _setState(LinkState.connected);
    } catch (e) {
      await _cancelSubscriptions();
      _setState(LinkState.disconnected);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    await _cancelSubscriptions();
    _failAll(
        const DeviceCommandError.disconnected(message: 'disconnected'));
    try {
      await device.disconnect();
    } catch (_) {}
    _setState(LinkState.disconnected);
  }

  void _cancelNotifySubscription() {
    final subscription = _notifySub;
    _notifySub = null;
    unawaited(subscription?.cancel());
  }

  Future<void> _cancelSubscriptions() async {
    final notify = _notifySub;
    _notifySub = null;
    await notify?.cancel();
    final connection = _connSub;
    _connSub = null;
    await connection?.cancel();
  }

  @override
  void setRawRxListener(RawRxListener? listener) => _rawRxListener = listener;

  void _onFrame(Uint8List frame) {
    final payload = decodeBleFrame(frame);
    if (payload == null) {
      if (frame.isNotEmpty) {
        onLog?.call('[BleDeviceLink] dropping oversized BLE frame '
            '(${frame.length} > $maxCompanionPayloadSize bytes)');
      }
      return;
    }
    frame = payload;
    if (frame[0] == pushCodeLogRxData) {
      final raw = RawRxFrame.parse(frame);
      if (raw != null) _rawRxListener?.call(raw.snr, raw.rssi, raw.raw);
      return;
    }
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      if (frame[0] == respCodeErr) {
        _pending = null;
        if (frame.length < 2) {
          pending.completeError(
            const DeviceCommandError.malformed(
              message: 'truncated ERR reply from device',
            ),
          );
        } else {
          pending.completeError(DeviceCommandError.device(frame[1]));
        }
      } else if (_expected.contains(frame[0])) {
        _pending = null;
        pending.complete(frame);
      }
    }
  }

  void _failAll(Object error) {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.completeError(error);
  }

  Future<void> _writeFrame(
      BluetoothCharacteristic rx, Uint8List frame) async {
    if (frame.length > maxCompanionPayloadSize) {
      throw ArgumentError.value(
        frame.length,
        'frame.length',
        'BLE payload exceeds $maxCompanionPayloadSize bytes',
      );
    }
    await rx.write(frame, withoutResponse: false);
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
      if (rx == null) {
        throw const DeviceCommandError.disconnected(
          message: 'BLE not connected',
        );
      }
      if (_pending != null) throw StateError('request already in flight');
      final completer = Completer<Uint8List>();
      _pending = completer;
      _expected = expected;
      try {
        await _writeFrame(rx, frame);
        return await completer.future.timeout(requestTimeout);
      } on TimeoutException {
        throw DeviceCommandError.timeout(
          message: 'BLE reply timed out after '
              '${requestTimeout.inMilliseconds}ms',
        );
      } finally {
        _pending = null;
      }
    });
  }

  Future<void> _requestOk(Uint8List frame) async {
    final reply = await _request(
      frame,
      {respCodeOk, respCodeErr, respCodeDisabled},
    );
    if (reply.isEmpty) {
      throw const DeviceCommandError.malformed(message: 'empty device reply');
    }
    if (reply[0] == respCodeDisabled) {
      throw const DeviceCommandError.disabled();
    }
    if (reply[0] != respCodeOk) {
      throw DeviceCommandError.malformed(
        message: 'unexpected device reply ${reply[0]}',
      );
    }
  }

  @override
  Future<void> sendRawPacket(Uint8List packet, [int priority = 0]) async {
    final rx = _rx;
    if (rx == null) throw StateError('BLE not connected');
    // The firmware replies OK/ERR for raw TX; consume it so it can't be
    // mistaken for another in-flight request's reply.
    await _request(
      DeviceFrames.sendRawPacket(packet, priority),
      {respCodeOk, respCodeErr},
    );
  }

  @override
  Future<DeviceInfo> deviceInfo() async {
    final frame =
        await _request(DeviceFrames.deviceQuery(), {respCodeDeviceInfo, respCodeErr});
    return TcpDeviceLink.parseDeviceInfo(frame);
  }

  @override
  Future<ParsedSelfInfo> selfInfo() async {
    final frame =
        await _request(DeviceFrames.appStart(), {respCodeSelfInfo, respCodeErr});
    final info = ParsedSelfInfo.parse(frame);
    if (info == null) {
      throw const DeviceCommandError.malformed(
        message: 'invalid SELF_INFO from device',
      );
    }
    return info;
  }

  @override
  Future<RadioParams> radioParams() async => (await selfInfo()).radioParams;

  @override
  Future<RadioStats> radioStats() async {
    final frame = await _request(
      DeviceFrames.getStats(statsTypeRadio),
      {respCodeStats, respCodeErr},
    );
    final stats = RadioStats.parse(frame);
    if (stats == null) {
      throw const DeviceCommandError.malformed(
        message: 'invalid radio stats from device',
      );
    }
    return stats;
  }

  @override
  Future<void> setRadioParams(RadioParams params, {bool? clientRepeat}) async {
    await _requestOk(DeviceFrames.setRadioParams(
      params,
      clientRepeat: clientRepeat,
    ));
  }

  @override
  Future<void> setTxPower(int dbm) async {
    await _requestOk(DeviceFrames.setTxPower(dbm));
  }

  @override
  Future<void> reboot() async {
    await _dispatchLifecycle(DeviceFrames.reboot());
  }

  @override
  Future<void> shutdown() async {
    await _dispatchLifecycle(DeviceFrames.shutdown());
  }

  /// Fire-and-forget lifecycle write. A disconnect observed after the write was
  /// dispatched is expected; a local/unrelated write failure is not.
  Future<void> _dispatchLifecycle(Uint8List payload) {
    final rx = _rx;
    if (rx == null) {
      throw const DeviceCommandError.disconnected(
        message: 'BLE not connected',
      );
    }
    return _runExclusive(() async {
      var attempted = false;
      try {
        attempted = true;
        await _writeFrame(rx, payload);
      } catch (e) {
        if (attempted && _state == LinkState.disconnected) return;
        rethrow;
      }
    });
  }

  @override
  Future<TuningParams> tuningParams() async {
    final frame = await _request(
      DeviceFrames.getTuningParams(),
      {respCodeTuningParams, respCodeErr},
    );
    final params = TuningParams.parse(frame);
    if (params == null) {
      throw const DeviceCommandError.malformed(
        message: 'invalid TUNING_PARAMS from device',
      );
    }
    return params;
  }

  @override
  Future<void> setTuningParams(TuningParams params) async {
    await _requestOk(DeviceFrames.setTuningParams(params));
  }

  @override
  Future<void> setPathHashMode(int mode) async {
    await _requestOk(DeviceFrames.setPathHashMode(mode));
  }

  @override
  Future<String> runCliCommand(String command) async {
    final frame = await _request(
      DeviceFrames.runCliCommand(command),
      {respCodeCliReply, respCodeDisabled, respCodeErr},
    );
    if (frame.isNotEmpty && frame[0] == respCodeDisabled) {
      throw const DeviceCommandError.disabled();
    }
    return String.fromCharCodes(frame.length > 1 ? frame.sublist(1) : const []);
  }

  @override
  Future<Uint8List> getAllowedRepeatFreq() async {
    final frame = await _request(
      DeviceFrames.getAllowedRepeatFreq(),
      {respCodeAllowedRepeatFreq, respCodeErr},
    );
    if (frame.isEmpty || frame[0] != respCodeAllowedRepeatFreq) {
      throw const DeviceCommandError.malformed(
        message: 'unexpected allowed-repeat-freq reply',
      );
    }
    return Uint8List.fromList(frame.sublist(1));
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

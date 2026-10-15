import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

import 'radio_link.dart';

/// [RadioLink] over TCP using the serial (`'<'`/`'>'`) framing.
///
/// Used for WiFi/Ethernet companion devices and for development against a
/// simulator.
class TcpDeviceLink implements RadioLink {
  TcpDeviceLink({
    required this.host,
    this.port = defaultCompanionPort,
    this.requestTimeout = const Duration(seconds: 5),
    this.onLog,
  });

  final String host;
  final int port;
  final Duration requestTimeout;
  final void Function(String message)? onLog;

  final SerialFrameCodec _codec = SerialFrameCodec();
  final _stateController = StreamController<LinkState>.broadcast();
  LinkState _state = LinkState.disconnected;
  Socket? _socket;
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
      final socket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 10));
      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;
      _codec.reset();
      socket.listen(
        _onData,
        onError: (Object e) => _failAll(StateError('device link error: $e')),
        onDone: () {
          _failAll(StateError('device link closed'));
          _setState(LinkState.disconnected);
        },
        cancelOnError: true,
      );
      _setState(LinkState.connected);
    } catch (e) {
      _setState(LinkState.disconnected);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    final socket = _socket;
    _socket = null;
    _failAll(StateError('disconnected'));
    await socket?.close();
    await socket?.done.catchError((_) {});
    _setState(LinkState.disconnected);
  }

  @override
  void setRawRxListener(RawRxListener? listener) => _rawRxListener = listener;

  void _onData(Uint8List data) {
    for (final frame in _codec.ingest(data)) {
      final frame_ = frame;
      if (frame_.isEmpty) continue;
      if (frame_[0] == pushCodeLogRxData) {
        final raw = RawRxFrame.parse(frame_);
        if (raw != null) _rawRxListener?.call(raw.snr, raw.rssi, raw.raw);
        continue;
      }
      final pending = _pending;
      if (pending != null && !pending.isCompleted) {
        if (_expected.contains(frame_[0])) {
          _pending = null;
          pending.complete(frame_);
        } else if (frame_[0] == respCodeErr) {
          _pending = null;
          pending.completeError(StateError('device returned error ${frame_[1]}'));
        }
      }
    }
  }

  void _failAll(Object error) {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.completeError(error);
  }

  /// Serialize request/response exchanges (one outstanding request at a time).
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
      final socket = _socket;
      if (socket == null) throw StateError('device link not connected');
      if (_pending != null) throw StateError('request already in flight');
      final completer = Completer<Uint8List>();
      _pending = completer;
      _expected = expected;
      try {
        socket.add(_codec.encodeFrame(frame, prefix: frameInboundPrefix));
        return await completer.future.timeout(requestTimeout);
      } finally {
        _pending = null;
      }
    });
  }

  @override
  Future<void> sendRawPacket(Uint8List packet, [int priority = 0]) async {
    // The firmware replies OK/ERR for raw TX. Await it so a stray response
    // cannot be mistaken for another in-flight request's reply.
    await _request(
      DeviceFrames.sendRawPacket(packet, priority),
      {respCodeOk, respCodeErr},
    );
  }

  @override
  Future<DeviceInfo> deviceInfo() async {
    final frame = await _request(
      DeviceFrames.deviceQuery(),
      {respCodeDeviceInfo, respCodeErr},
    );
    return parseDeviceInfo(frame);
  }

  @override
  Future<RadioParams> radioParams() async {
    final frame =
        await _request(DeviceFrames.appStart(), {respCodeSelfInfo, respCodeErr});
    final info = ParsedSelfInfo.parse(frame);
    if (info == null) throw StateError('invalid SELF_INFO from device');
    return info.radioParams;
  }

  /// Read the full device SELF_INFO (radio params + name + location).
  Future<ParsedSelfInfo> selfInfo() async {
    final frame =
        await _request(DeviceFrames.appStart(), {respCodeSelfInfo, respCodeErr});
    final info = ParsedSelfInfo.parse(frame);
    if (info == null) throw StateError('invalid SELF_INFO from device');
    return info;
  }

  @override
  Future<void> setRadioParams(RadioParams params) async {
    await _request(
      DeviceFrames.setRadioParams(params),
      {respCodeOk, respCodeErr},
    );
  }

  @override
  Future<void> setTxPower(int dbm) async {
    await _request(DeviceFrames.setTxPower(dbm), {respCodeOk, respCodeErr});
  }

  @override
  Future<void> reboot() async {
    // The firmware reboots the hardware without sending a reply, so this is a
    // fire-and-forget write (not a request/response exchange).
    await _runExclusive(() async {
      final socket = _socket;
      if (socket == null) throw StateError('device link not connected');
      socket.add(
        _codec.encodeFrame(DeviceFrames.reboot(), prefix: frameInboundPrefix),
      );
    });
  }

  @override
  Future<TuningParams> tuningParams() async {
    final frame = await _request(
      DeviceFrames.getTuningParams(),
      {respCodeTuningParams, respCodeErr},
    );
    final params = TuningParams.parse(frame);
    if (params == null) throw StateError('invalid TUNING_PARAMS from device');
    return params;
  }

  @override
  Future<void> setTuningParams(TuningParams params) async {
    await _request(
      DeviceFrames.setTuningParams(params),
      {respCodeOk, respCodeErr},
    );
  }

  @override
  Future<void> setPathHashMode(int mode) async {
    await _request(
      DeviceFrames.setPathHashMode(mode),
      {respCodeOk, respCodeErr},
    );
  }

  @override
  Future<BatteryReading?> battery() async {
    try {
      final frame = await _request(
        DeviceFrames.getBattAndStorage(),
        {respCodeBattAndStorage, respCodeErr},
      );
      final r = BufferReader(frame)..skipBytes(1);
      final mv = r.readUInt16Le();
      final used = r.readUInt32Le();
      final total = r.readUInt32Le();
      return BatteryReading(
          millivolts: mv, storageUsedKb: used, storageTotalKb: total);
    } catch (e) {
      onLog?.call('[TcpDeviceLink] battery read failed: $e');
      return null;
    }
  }

  /// Run a CLI command on the device (firmware v14+).
  @override
  Future<String> runCliCommand(String command) async {
    final frame = await _request(
      DeviceFrames.runCliCommand(command),
      {respCodeCliReply, respCodeErr},
    );
    return String.fromCharCodes(frame.length > 1 ? frame.sublist(1) : const []);
  }

  @override
  Future<Uint8List?> exportPrivateKey() async {
    final frame = await _request(
      DeviceFrames.exportPrivateKey(),
      {respCodePrivateKey, respCodeDisabled, respCodeErr},
    );
    return parsePrivateKeyReply(frame);
  }

  @override
  Future<Uint8List> getAllowedRepeatFreq() async {
    final frame = await _request(
      DeviceFrames.getAllowedRepeatFreq(),
      {respCodeAllowedRepeatFreq, respCodeErr},
    );
    if (frame.isEmpty || frame[0] != respCodeAllowedRepeatFreq) {
      throw StateError('unexpected allowed-repeat-freq reply');
    }
    return Uint8List.fromList(frame.sublist(1));
  }

  /// Parse `RESP_CODE_DEVICE_INFO`.
  static DeviceInfo parseDeviceInfo(Uint8List frame) {
    if (frame.length < 4) throw StateError('truncated DEVICE_INFO');
    final fw = frame[1];
    final maxContacts = frame[2] * 2;
    final maxChannels = frame[3];
    String cstring(int start, int len) {
      if (frame.length < start + len) return '';
      final bytes = frame.sublist(start, start + len);
      final end = bytes.indexOf(0);
      return String.fromCharCodes(end >= 0 ? bytes.sublist(0, end) : bytes).trim();
    }

    return DeviceInfo(
      firmwareVerCode: fw,
      maxContacts: maxContacts > 0 ? maxContacts : 1000,
      maxChannels: maxChannels > 0 ? maxChannels : 8,
      manufacturer: cstring(20, 40),
      version: cstring(60, 20),
      clientRepeat: frame.length >= 81 ? frame[80] : 0,
      pathHashMode: frame.length >= 82 ? (frame[81] & 0xFF).clamp(0, 3) : 0,
    );
  }
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

import 'errors.dart';
import 'radio_link.dart';

/// Opens the TCP socket for [TcpDeviceLink].
typedef TcpSocketConnector = Future<Socket> Function(
  String host,
  int port,
  Duration timeout,
);

Future<Socket> _connectSocket(String host, int port, Duration timeout) =>
    Socket.connect(host, port, timeout: timeout);

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
    this.socketConnector = _connectSocket,
  });

  final String host;
  final int port;
  final Duration requestTimeout;
  final void Function(String message)? onLog;
  final TcpSocketConnector socketConnector;

  // A device only sends radio→app (outbound '>') frames.
  final SerialFrameCodec _codec =
      SerialFrameCodec(direction: FrameDirection.outbound);
  final _stateController = StreamController<LinkState>.broadcast();
  LinkState _state = LinkState.disconnected;
  Socket? _socket;
  RawRxListener? _rawRxListener;

  Completer<Uint8List>? _pending;
  Set<int> _expected = const {};
  Future<void> _lock = Future<void>.value();

  /// Invalidates an in-flight [Socket.connect] when the connection is canceled.
  ///
  /// `dart:io` cannot abort a connecting socket, so a canceled attempt is left
  /// to unwind and its socket is discarded instead of becoming the live link.
  int _connectGeneration = 0;

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
    final generation = ++_connectGeneration;
    _setState(LinkState.connecting);
    try {
      final socket = await socketConnector(
        host,
        port,
        const Duration(seconds: 10),
      );
      if (generation != _connectGeneration) {
        socket.destroy();
        return;
      }
      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;
      _codec.reset();
      // `listen` reports link state, but a failed write can also complete
      // `done` with the same error. Observe it so a closed peer never leaves an
      // unhandled asynchronous error behind.
      unawaited(socket.done.catchError((_) {}));
      socket.listen(
        _onData,
        onError: (Object e) {
          if (identical(_socket, socket)) _socket = null;
          _failAll(
            DeviceCommandError.disconnected(message: 'device link error: $e'),
          );
          _setState(LinkState.disconnected);
        },
        onDone: () {
          if (identical(_socket, socket)) _socket = null;
          _failAll(
            const DeviceCommandError.disconnected(
                message: 'device link closed'),
          );
          _setState(LinkState.disconnected);
        },
        cancelOnError: true,
      );
      _setState(LinkState.connected);
    } catch (e) {
      if (generation == _connectGeneration) {
        _setState(LinkState.disconnected);
      }
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    _connectGeneration++;
    final socket = _socket;
    _socket = null;
    _failAll(const DeviceCommandError.disconnected(message: 'disconnected'));
    await socket?.close();
    await socket?.done.catchError((_) {});
    _setState(LinkState.disconnected);
  }

  @override
  void setRawRxListener(RawRxListener? listener) => _rawRxListener = listener;

  void _onData(Uint8List data) {
    for (final frame in _codec.ingest(data)) {
      if (frame.isEmpty) continue;
      if (frame[0] == pushCodeLogRxData) {
        final raw = RawRxFrame.parse(frame);
        if (raw != null) _rawRxListener?.call(raw.snr, raw.rssi, raw.raw);
        continue;
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

  Socket _requireSocket() {
    final socket = _socket;
    if (socket == null) {
      throw const DeviceCommandError.disconnected(
        message: 'device link not connected',
      );
    }
    return socket;
  }

  Future<Uint8List> _request(Uint8List frame, Set<int> expected) {
    return _runExclusive(() async {
      final socket = _requireSocket();
      final completer = Completer<Uint8List>();
      _pending = completer;
      _expected = expected;
      try {
        socket.add(_codec.encodeFrame(frame, prefix: frameInboundPrefix));
      } on SocketException catch (e) {
        _pending = null;
        throw DeviceCommandError.disconnected(
          message: 'device write failed: ${e.message}',
        );
      }
      try {
        return await completer.future.timeout(requestTimeout);
      } on TimeoutException {
        // A reply that arrives after the timeout cannot be matched to this
        // request. Drop the connection so it cannot satisfy the next request
        // with the same expected response code.
        _pending = null;
        await disconnect();
        throw DeviceCommandError.timeout(
          message: 'device reply timed out after '
              '${requestTimeout.inMilliseconds}ms',
        );
      } finally {
        _pending = null;
      }
    });
  }

  /// Send a setter and require a definite `OK`; a DISABLED reply preserves its
  /// semantic (the caller maps it to the one-byte DISABLED response).
  Future<void> _requestOk(Uint8List frame) async {
    final reply = await _request(
      frame,
      {respCodeOk, respCodeDisabled},
    );
    if (reply.isEmpty) {
      throw const DeviceCommandError.malformed(
        message: 'empty device reply',
      );
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
    // The firmware replies OK/ERR for raw TX. Await it so a stray response
    // cannot be mistaken for another in-flight request's reply.
    await _request(
      DeviceFrames.sendRawPacket(packet, priority),
      {respCodeOk},
    );
  }

  @override
  Future<DeviceInfo> deviceInfo() async {
    final frame = await _request(
      DeviceFrames.deviceQuery(),
      {respCodeDeviceInfo},
    );
    return parseDeviceInfo(frame);
  }

  @override
  Future<RadioParams> radioParams() async => (await selfInfo()).radioParams;

  @override
  Future<RadioStats> radioStats() async {
    final frame = await _request(
      DeviceFrames.getStats(statsTypeRadio),
      {respCodeStats},
    );
    final stats = RadioStats.parse(frame);
    if (stats == null) {
      throw const DeviceCommandError.malformed(
        message: 'invalid radio stats from device',
      );
    }
    return stats;
  }

  /// Read the full device SELF_INFO (radio params + name + location).
  @override
  Future<ParsedSelfInfo> selfInfo() async {
    final frame = await _request(DeviceFrames.appStart(), {respCodeSelfInfo});
    final info = ParsedSelfInfo.parse(frame);
    if (info == null) {
      throw const DeviceCommandError.malformed(
        message: 'invalid SELF_INFO from device',
      );
    }
    return info;
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
    await _dispatchLifecycle(DeviceFrames.reboot(), 'reboot');
  }

  @override
  Future<void> shutdown() async {
    await _dispatchLifecycle(DeviceFrames.shutdown(), 'shutdown');
  }

  /// Fire-and-forget lifecycle write: flush the transport, but never wait for a
  /// firmware reply (reboot/poweroff do not send one).
  Future<void> _dispatchLifecycle(Uint8List payload, String action) {
    return _runExclusive(() async {
      final socket = _requireSocket();
      try {
        socket.add(
          _codec.encodeFrame(payload, prefix: frameInboundPrefix),
        );
        await socket.flush();
      } on SocketException catch (e) {
        throw DeviceCommandError.disconnected(
          message: '$action dispatch failed: ${e.message}',
        );
      }
    });
  }

  @override
  Future<TuningParams> tuningParams() async {
    final frame = await _request(
      DeviceFrames.getTuningParams(),
      {respCodeTuningParams},
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
  Future<BatteryReading?> battery() async {
    try {
      final frame = await _request(
        DeviceFrames.getBattAndStorage(),
        {respCodeBattAndStorage},
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
      {respCodeCliReply, respCodeDisabled},
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
      {respCodeAllowedRepeatFreq},
    );
    if (frame.isEmpty || frame[0] != respCodeAllowedRepeatFreq) {
      throw const DeviceCommandError.malformed(
        message: 'unexpected allowed-repeat-freq reply',
      );
    }
    return Uint8List.fromList(frame.sublist(1));
  }

  /// Parse `RESP_CODE_DEVICE_INFO`.
  static DeviceInfo parseDeviceInfo(Uint8List frame) {
    if (frame.length < 4) {
      throw const DeviceCommandError.malformed(
        message: 'truncated DEVICE_INFO',
      );
    }
    final fw = frame[1];
    final maxContacts = frame[2] * 2;
    final maxChannels = frame[3];
    String cstring(int start, int len) {
      if (frame.length < start + len) return '';
      final bytes = frame.sublist(start, start + len);
      final end = bytes.indexOf(0);
      return String.fromCharCodes(end >= 0 ? bytes.sublist(0, end) : bytes)
          .trim();
    }

    const defaults = DeviceInfo();
    return DeviceInfo(
      firmwareVerCode: fw,
      maxContacts: maxContacts > 0 ? maxContacts : defaults.maxContacts,
      maxChannels: maxChannels > 0 ? maxChannels : defaults.maxChannels,
      manufacturer: cstring(20, 40),
      version: cstring(60, 20),
      clientRepeat: frame.length >= 81 ? frame[80] : 0,
      pathHashMode: frame.length >= 82 ? (frame[81] & 0xFF).clamp(0, 3) : 0,
    );
  }
}

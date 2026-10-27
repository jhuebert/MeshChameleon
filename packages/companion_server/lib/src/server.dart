import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

import 'bridge.dart';
import 'metrics.dart';

/// Configuration for [CompanionServer].
class CompanionServerConfig {
  const CompanionServerConfig({
    this.port = defaultCompanionPort,
    this.bindAddress = '0.0.0.0',
    this.clientIdleTimeout = const Duration(seconds: 120),
    this.heartbeatInterval = Duration.zero,
    this.maxSignDataLen = 8 * 1024,
  });

  final int port;
  final String bindAddress;
  final Duration clientIdleTimeout;

  /// Periodic `RESP_CODE_CURR_TIME` heartbeat. Disabled when zero.
  final Duration heartbeatInterval;
  final int maxSignDataLen;
}

/// App-facing MeshCore companion TCP server.
///
/// Reads `'<'` framed commands from a single client, dispatches them to a
/// [CompanionBridge], and writes `'>'` framed responses and pushes. A new
/// connection evicts the previous one.
class CompanionServer implements CompanionPushSink {
  CompanionServer({
    required CompanionBridge bridge,
    this.config = const CompanionServerConfig(),
    this.onLog,
    CompanionMetrics? metrics,
  })  : _bridge = bridge,
        metrics = metrics ?? CompanionMetrics();

  CompanionBridge _bridge;

  /// The bridge currently bound to the app-facing session.
  CompanionBridge get bridge => _bridge;

  final CompanionServerConfig config;
  final void Function(String message)? onLog;

  /// Session-only client traffic counters. The app may retain this object
  /// across proxy restarts so its totals survive a stop/start.
  final CompanionMetrics metrics;

  ServerSocket? _server;
  Socket? _client;
  // The app-facing server only accepts app→radio ('<') frames.
  final SerialFrameCodec _codec =
      SerialFrameCodec(direction: FrameDirection.inbound);
  Timer? _idleTimer;
  Timer? _heartbeatTimer;
  int _appTargetVer = 0;
  final List<int> _signBuffer = <int>[];

  /// Commands are executed in arrival order, one at a time.
  Future<void> _commandTail = Future<void>.value();

  /// Incremented when a client connects/disconnects. Replies from an older
  /// command generation are dropped rather than sent to a replacement client.
  int _connectionGeneration = 0;
  int? _commandGeneration;
  bool _switchingBridge = false;

  int? get port => _server?.port;
  bool get hasClient => _client != null;

  Future<void> start() async {
    if (_server != null) return;
    final server = await ServerSocket.bind(config.bindAddress, config.port);
    _server = server;
    _log('listening on ${config.bindAddress}:${server.port}');
    server.listen(
      _handleClient,
      onError: (Object e) => _log('server error: $e'),
    );
  }

  Future<void> stop() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    _disconnectClient(reason: 'server stop');
    _bridge.setPushSink(null);
    await _server?.close();
    _server = null;
  }

  /// Disconnect the current app client without closing the listener.
  Future<void> disconnectClient({required String reason}) async {
    if (_client != null) _disconnectClient(reason: reason);
  }

  /// Install [next] as the bridge for future clients.
  ///
  /// The current client is disconnected immediately so no old-session command
  /// can be accepted. A barrier on the command tail waits for the in-flight
  /// command to finish before the bridge changes; commands enqueued by a client
  /// that connects during the barrier run only after the new bridge is in
  /// place. The listener socket stays open.
  Future<void> switchBridge(CompanionBridge next) {
    _switchingBridge = true;
    _disconnectClient(reason: 'identity switch');
    final completer = Completer<void>();
    _commandTail = _commandTail.then((_) async {
      try {
        final previous = _bridge;
        if (!identical(previous, next)) {
          previous.setPushSink(null);
          _bridge = next;
        }
        _switchingBridge = false;
        _bridge.setPushSink(_client == null ? null : this);
      } finally {
        _switchingBridge = false;
        if (!completer.isCompleted) completer.complete();
      }
    }).catchError((Object e) {
      _switchingBridge = false;
      _log('bridge switch error: $e');
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }

  // -------------------------------------------------------------------------
  // Client lifecycle
  // -------------------------------------------------------------------------

  void _handleClient(Socket socket) {
    _log('client connected from ${socket.remoteAddress.address}');
    if (_client != null) {
      _log('evicting previous client');
      final old = _client;
      _client = null;
      metrics.clientEvicted();
      old?.destroy();
    }
    _client = socket;
    metrics.recordClientConnected(socket.remoteAddress.address);
    _connectionGeneration++;
    final generation = _connectionGeneration;
    _codec.reset();
    _signBuffer.clear();
    socket.setOption(SocketOption.tcpNoDelay, true);
    // During a bridge switch the new bridge is installed by the barrier; the
    // old bridge must not receive a new client's push sink in the meantime.
    if (!_switchingBridge) _bridge.setPushSink(this);
    _appTargetVer = 0;

    socket.listen(
      (data) {
        if (!identical(socket, _client)) return;
        _resetIdleTimer();
        final frames = _codec.ingest(data);
        for (final frame in frames) {
          metrics.commandReceived(frame.length);
          _enqueueCommand(generation, frame);
        }
      },
      onError: (Object e) {
        if (!identical(socket, _client)) return;
        _log('client error: $e');
        _disconnectClient(reason: 'error', error: true);
      },
      onDone: () {
        if (!identical(socket, _client)) return;
        _disconnectClient(reason: 'closed');
      },
      cancelOnError: true,
    );
    _resetIdleTimer();
    _startHeartbeat();
  }

  /// Run [frame] after all earlier commands, scoped to [generation]. Only one
  /// application operation reaches the bridge/device at a time.
  void _enqueueCommand(int generation, Uint8List frame) {
    _commandTail = _commandTail.then((_) async {
      _commandGeneration = generation;
      try {
        await _handleCommand(frame);
      } finally {
        _commandGeneration = null;
      }
    }).catchError((Object e) {
      _log('command queue error: $e');
    });
  }

  void _disconnectClient({
    required String reason,
    bool error = false,
    bool idleTimeout = false,
  }) {
    final client = _client;
    _client = null;
    _connectionGeneration++;
    _signBuffer.clear();
    if (client != null) {
      metrics.clientDisconnected(reason,
          error: error, idleTimeout: idleTimeout);
    }
    _log('client disconnected: $reason');
    _bridge.setPushSink(null);
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    try {
      client?.destroy();
    } catch (_) {}
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    if (config.clientIdleTimeout <= Duration.zero) return;
    _idleTimer = Timer(config.clientIdleTimeout, () {
      _disconnectClient(reason: 'idle timeout', idleTimeout: true);
    });
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    if (config.heartbeatInterval <= Duration.zero) return;
    _heartbeatTimer = Timer.periodic(config.heartbeatInterval, (_) {
      _sendPushFrame(_u32Frame(respCodeCurrTime, bridge.getTime()));
    });
  }

  // -------------------------------------------------------------------------
  // Frame I/O
  // -------------------------------------------------------------------------

  /// Send a command reply. Replies from an older client generation are dropped.
  void _sendFrame(List<int> payload, {bool error = false}) {
    final generation = _commandGeneration;
    if (generation != null && generation != _connectionGeneration) {
      _log('dropping reply from evicted client generation $generation');
      return;
    }
    _writeTo(_client, payload, push: false, error: error);
  }

  /// Send an asynchronous push to the current client regardless of which
  /// command is awaiting a device reply.
  void _sendPushFrame(List<int> payload) =>
      _writeTo(_client, payload, push: true);

  void _writeTo(
    Socket? client,
    List<int> payload, {
    required bool push,
    bool error = false,
  }) {
    if (client == null) return;
    try {
      client.add(_codec.encodeFrame(payload));
      if (push) {
        metrics.pushSent(payload.length);
      } else {
        metrics.replySent(payload.length);
        if (error) metrics.errorReplySent();
      }
    } catch (e) {
      metrics.writeFailed();
      _log('write failed: $e');
      if (identical(client, _client)) {
        _disconnectClient(reason: 'write failed', error: true);
      }
    }
  }

  void sendOk() => _sendFrame(Uint8List.fromList([respCodeOk]));

  void sendErr(int code) =>
      _sendFrame(Uint8List.fromList([respCodeErr, code]), error: true);

  void sendDisabled() =>
      _sendFrame(Uint8List.fromList([respCodeDisabled]), error: true);

  void _sendOperationError(CompanionOperationError e) {
    if (e.message != null) {
      _log('physical operation failed: ${e.message}');
    }
    if (e.uncertain) {
      _log('physical operation outcome is uncertain; no automatic retry');
    }
    if (e.disabled) {
      sendDisabled();
    } else {
      sendErr(e.code);
    }
  }

  static Uint8List _u32Frame(int code, int value) {
    final w = BufferWriter()
      ..writeByte(code)
      ..writeUInt32Le(value);
    return w.toBytes();
  }

  // -------------------------------------------------------------------------
  // Push sink
  // -------------------------------------------------------------------------

  @override
  void pushMsgWaiting() =>
      _sendPushFrame(Uint8List.fromList([pushCodeMsgWaiting]));

  @override
  void pushSendConfirmed(int ackCrc, {int tripTimeMs = 0}) => _sendPushFrame(
        (BufferWriter()
              ..writeByte(pushCodeSendConfirmed)
              ..writeUInt32Le(ackCrc)
              ..writeUInt32Le(tripTimeMs))
            .toBytes(),
      );

  @override
  void pushAdvert(Uint8List pubkey) => _sendPushFrame(
      Uint8List.fromList([pushCodeAdvert, ...pubkey.take(pubKeySize)]));

  @override
  void pushNewAdvert(Uint8List contactFrame) =>
      _sendPushFrame(Uint8List.fromList([pushCodeNewAdvert, ...contactFrame]));

  @override
  void pushContactDeleted(Uint8List pubkey) => _sendPushFrame(
      Uint8List.fromList([pushCodeContactDeleted, ...pubkey.take(pubKeySize)]));

  @override
  void pushContactsFull() =>
      _sendPushFrame(Uint8List.fromList([pushCodeContactsFull]));

  @override
  void pushPathUpdated(Uint8List pubkey) => _sendPushFrame(
      Uint8List.fromList([pushCodePathUpdated, ...pubkey.take(pubKeySize)]));

  @override
  void pushTelemetryResponse(Uint8List pubkeyPrefix6, Uint8List data) =>
      _sendPushFrame(Uint8List.fromList(
          [pushCodeTelemetryResponse, 0, ...pubkeyPrefix6.take(6), ...data]));

  @override
  void pushBinaryResponse(int tag, Uint8List data) =>
      _sendPushFrame(Uint8List.fromList([
        pushCodeBinaryResponse,
        0,
        tag & 0xFF,
        (tag >> 8) & 0xFF,
        (tag >> 16) & 0xFF,
        (tag >> 24) & 0xFF,
        ...data
      ]));

  @override
  void pushRawRxData(double snr, int rssi, Uint8List raw) {
    final snrByte = (snr * 4).round().clamp(-128, 127) & 0xFF;
    _sendPushFrame(Uint8List.fromList([
      pushCodeLogRxData,
      snrByte,
      rssi & 0xFF,
      ...raw,
    ]));
  }

  @override
  void pushRawData(double snr, int rssi, Uint8List payload) {
    final snrByte = (snr * 4).round().clamp(-128, 127) & 0xFF;
    final rssiByte = rssi.clamp(-128, 127);
    _sendPushFrame(Uint8List.fromList([
      pushCodeRawData,
      snrByte,
      rssiByte & 0xFF,
      0xFF,
      ...payload,
    ]));
  }

  @override
  void pushPathDiscoveryResponse(Uint8List pubkeyPrefix6, int outPathLen,
      Uint8List outPath, int inPathLen, Uint8List inPath) {
    final w = BufferWriter()
      ..writeByte(pushCodePathDiscoveryResponse)
      ..writeByte(0) // reserved
      ..writeBytes(pubkeyPrefix6.take(6).toList())
      ..writeByte(outPathLen & 0xFF)
      ..writeBytes(outPath)
      ..writeByte(inPathLen & 0xFF)
      ..writeBytes(inPath);
    _sendPushFrame(w.toBytes());
  }

  @override
  void pushLoginSuccess(
    Uint8List pubkeyPrefix6, {
    bool legacy = false,
    int permissions = 0,
    int serverTag = 0,
    int acl = 0,
    int firmwareVer = 0,
  }) {
    final w = BufferWriter()
      ..writeByte(pushCodeLoginSuccess)
      ..writeByte(legacy ? 0 : (permissions & 0xFF))
      ..writeBytes(pubkeyPrefix6.take(6).toList());
    if (!legacy) {
      w
        ..writeUInt32Le(serverTag)
        ..writeByte(acl & 0xFF)
        ..writeByte(firmwareVer & 0xFF);
    }
    _sendPushFrame(w.toBytes());
  }

  @override
  void pushLoginFail(Uint8List pubkeyPrefix6) => _sendPushFrame(
      Uint8List.fromList([pushCodeLoginFail, 0, ...pubkeyPrefix6.take(6)]));

  @override
  void pushStatusResponse(Uint8List pubkeyPrefix6, Uint8List data) =>
      _sendPushFrame(Uint8List.fromList(
          [pushCodeStatusResponse, 0, ...pubkeyPrefix6.take(6), ...data]));

  @override
  void pushControlData(double snr, int rssi, int pathLen, Uint8List data) {
    var snrByte = (snr * 4).round().clamp(-128, 127);
    if (snrByte < 0) snrByte += 256;
    var rssiByte = rssi.clamp(-128, 127);
    if (rssiByte < 0) rssiByte += 256;
    _sendPushFrame(Uint8List.fromList([
      pushCodeControlData,
      snrByte & 0xFF,
      rssiByte & 0xFF,
      pathLen & 0xFF,
      ...data,
    ]));
  }

  @override
  void pushTraceData(
    int pathLen,
    int flags,
    int tag,
    int authCode,
    Uint8List pathHashes,
    Uint8List pathSnrs,
    int finalSnrByte,
  ) {
    final w = BufferWriter()
      ..writeByte(pushCodeTraceData)
      ..writeByte(0) // reserved
      ..writeByte(pathLen & 0xFF)
      ..writeByte(flags & 0xFF)
      ..writeUInt32Le(tag & 0xFFFFFFFF)
      ..writeUInt32Le(authCode & 0xFFFFFFFF)
      ..writeBytes(pathHashes)
      ..writeBytes(pathSnrs)
      ..writeByte(finalSnrByte & 0xFF);
    _sendPushFrame(w.toBytes());
  }

  // -------------------------------------------------------------------------
  // Command dispatch
  // -------------------------------------------------------------------------

  Future<void> _handleCommand(Uint8List payload) async {
    if (payload.isEmpty) {
      sendErr(errCodeIllegalArg);
      return;
    }
    final cmd = payload[0];
    final data = Uint8List.sublistView(payload, 1);
    _log('cmd 0x${cmd.toRadixString(16)} len=${payload.length}');
    try {
      await _dispatch(cmd, data);
    } on CompanionOperationError catch (e) {
      _sendOperationError(e);
    } catch (e) {
      _log('cmd 0x${cmd.toRadixString(16)} error: $e');
      sendErr(errCodeIllegalArg);
    }
  }

  Future<void> _dispatch(int cmd, Uint8List data) async {
    switch (cmd) {
      case cmdDeviceQuery:
        _cmdDeviceQuery(data);
      case cmdAppStart:
        _cmdAppStart(data);
      case cmdGetDeviceTime:
        _sendFrame(_u32Frame(respCodeCurrTime, bridge.getTime()));
      case cmdSetDeviceTime:
        if (data.length < 4) return sendErr(errCodeIllegalArg);
        final reader = BufferReader(data);
        final secs = reader.readUInt32Le();
        bridge.setTime(secs) ? sendOk() : sendErr(errCodeIllegalArg);
      case cmdGetBattAndStorage:
        await _cmdBattery();
      case cmdGetCustomVars:
        _cmdCustomVars();
      case cmdSetCustomVar:
        _cmdSetCustomVar(data);
      case cmdGetAutoAddConfig:
        _sendFrame(Uint8List.fromList([
          respCodeAutoAddConfig,
          bridge.getAutoAddConfig() & 0xFF,
          bridge.getAutoAddMaxHops() & 0xFF,
        ]));
      case cmdSetAutoAddConfig:
        if (data.isEmpty) return sendErr(errCodeIllegalArg);
        final maxHops = data.length >= 2 ? data[1].clamp(0, 64) : null;
        try {
          await bridge.setAutoAddConfig(data[0], maxHops);
          sendOk();
        } on CompanionOperationError catch (e) {
          _sendOperationError(e);
        }
      case cmdSetOtherParams:
        await _cmdSetOtherParams(data);
      case cmdSetRadioParams:
        await _cmdSetRadioParams(data);
      case cmdSetRadioTxPower:
        await _cmdSetTxPower(data);
      // These commands are intentionally disabled for the proxy: never change
      // physical device settings/state or PIN/reset.
      case cmdSetDevicePin:
        sendDisabled();
      case cmdFactoryReset:
        sendDisabled();
      // Virtual identity import/export never touches the physical identity.
      case cmdExportPrivateKey:
        await _cmdExportPrivateKey();
      case cmdImportPrivateKey:
        await _cmdImportPrivateKey(data);
      case cmdGetTuningParams:
        await _cmdGetTuningParams();
      case cmdSetTuningParams:
        await _cmdSetTuningParams(data);
      case cmdSetPathHashMode:
        await _cmdSetPathHashMode(data);
      case cmdRunCliCommand:
        await _cmdRunCliCommand(data);
      case cmdGetContacts:
        _cmdGetContacts(data);
      case cmdGetContactByKey:
        _cmdGetContactByKey(data);
      case cmdAddUpdateContact:
        await _cmdAddUpdateContact(data);
      case cmdRemoveContact:
        await _cmdRemoveContact(data);
      case cmdResetPath:
        await _cmdResetPath(data);
      case cmdGetChannel:
        _cmdGetChannel(data);
      case cmdSetChannel:
        await _cmdSetChannel(data);
      case cmdSendSelfAdvert:
        await _cmdSendSelfAdvert(data);
      case cmdSetAdvertName:
        await _cmdSetAdvertName(data);
      case cmdSetAdvertLatLon:
        await _cmdSetAdvertLatLon(data);
      case cmdSendTxtMsg:
        await _cmdSendTxt(data);
      case cmdSendChannelTxtMsg:
        await _cmdSendChannelTxt(data);
      case cmdSendChannelData:
        await _cmdSendChannelData(data);
      case cmdSendControlData:
        await _cmdSendControlData(data);
      case cmdSyncNextMessage:
        await _cmdSyncNextMessage();
      case cmdSignStart:
        _cmdSignStart();
      case cmdSignData:
        _cmdSignData(data);
      case cmdSignFinish:
        await _cmdSignFinish();
      case cmdGetStats:
        await _cmdGetStats(data);
      case cmdGetAllowedRepeatFreq:
        await _cmdGetAllowedRepeatFreq();
      case cmdGetAdvertPath:
        _cmdGetAdvertPath(data);
      case cmdExportContact:
        await _cmdExportContact(data);
      case cmdImportContact:
        await _cmdImportContact(data);
      case cmdShareContact:
        await _cmdShareContact(data);
      case cmdSendBinaryReq:
        await _cmdSendBinaryReq(data);
      case cmdSendAnonReq:
        await _cmdSendAnonReq(data);
      case cmdSendTelemetryReq:
        await _cmdSendTelemetryReq(data);
      case cmdSendTracePath:
        await _cmdSendTracePath(data);
      case cmdSendPathDiscoveryReq:
        await _cmdSendPathDiscoveryReq(data);
      case cmdSendLogin:
        await _cmdSendLogin(data);
      case cmdSendStatusReq:
        await _cmdSendStatusReq(data);
      case cmdSendRawData:
        await _cmdSendRawData(data);
      case cmdSendRawPacket:
        await _cmdSendRawPacket(data);
      case cmdLogout:
        _cmdLogout(data);
      case cmdHasConnection:
        _cmdHasConnection(data);
      case cmdSetFloodScope:
        _cmdSetFloodScope(data);
      case cmdSetDefaultFloodScope:
        await _cmdSetDefaultFloodScope(data);
      case cmdGetDefaultFloodScope:
        _cmdGetDefaultFloodScope();
      case cmdReboot:
        await _cmdReboot(data);
      default:
        metrics.unsupportedCommandReceived();
        _log('unsupported cmd 0x${cmd.toRadixString(16)}');
        sendErr(errCodeUnsupportedCmd);
    }
  }

  // -------------------------------------------------------------------------
  // Handshake / info
  // -------------------------------------------------------------------------

  void _cmdDeviceQuery(Uint8List data) {
    if (data.isNotEmpty) {
      _appTargetVer = data[0];
      metrics.appTargetVersionReceived(data[0]);
    }
    final info = bridge.getDeviceInfo();
    final w = BufferWriter()
      ..writeByte(respCodeDeviceInfo)
      ..writeByte(info.firmwareVerCode)
      ..writeByte((info.maxContacts ~/ 2).clamp(0, 255))
      ..writeByte(info.maxChannels.clamp(0, 255))
      ..writeUInt32Le(info.blePin);
    _writeFixedString(w, info.buildDate, 12);
    _writeFixedString(w, info.manufacturer, 40);
    _writeFixedString(w, info.version, 20);
    w.writeByte(info.clientRepeat & 0xFF);
    w.writeByte(bridge.getPathHashMode() & 0xFF);
    _sendFrame(w.toBytes());
  }

  void _cmdAppStart(Uint8List data) {
    if (data.isNotEmpty) {
      _appTargetVer = data[0];
      metrics.appTargetVersionReceived(data[0]);
    }
    final prefs = bridge.getSelfInfo();
    final pubkey = bridge.getPublicKey();
    final w = BufferWriter()
      ..writeByte(respCodeSelfInfo)
      ..writeByte(prefs.advType)
      ..writeByte(prefs.txPowerDbm)
      ..writeByte(prefs.maxTxPower)
      ..writeBytes(pubkey)
      ..writeInt32Le((prefs.latitude * 1e6).round())
      ..writeInt32Le((prefs.longitude * 1e6).round())
      ..writeByte(prefs.multiAcks)
      ..writeByte(prefs.advertLocPolicy)
      ..writeByte(prefs.telemetryModes)
      ..writeByte(prefs.manualAddContacts)
      ..writeUInt32Le(prefs.frequencyHz ~/ 1000) // kHz, as the firmware reports
      ..writeUInt32Le(prefs.bandwidthHz)
      ..writeByte(prefs.spreadingFactor)
      ..writeByte(prefs.codingRate)
      ..writeString(prefs.nodeName);
    _sendFrame(w.toBytes());
  }

  Future<void> _cmdBattery() async {
    final b = await bridge.getBatteryAndStorage();
    final w = BufferWriter()
      ..writeByte(respCodeBattAndStorage)
      ..writeUInt16Le(b.millivolts)
      ..writeUInt32Le(b.storageUsedKb)
      ..writeUInt32Le(b.storageTotalKb);
    _sendFrame(w.toBytes());
  }

  void _cmdCustomVars() {
    final vars = bridge.getCustomVars();
    final csv = vars.entries.map((e) => '${e.key}:${e.value}').join(',');
    final bytes = csv.length > 140 ? csv.substring(0, 140) : csv;
    final w = BufferWriter()
      ..writeByte(respCodeCustomVars)
      ..writeString(bytes);
    _sendFrame(w.toBytes());
  }

  Future<void> _cmdSetCustomVar(Uint8List data) async {
    if (data.length < 3) return sendErr(errCodeIllegalArg);
    String text;
    try {
      text = utf8.decode(data);
    } on FormatException {
      return sendErr(errCodeIllegalArg);
    }
    final sep = text.indexOf(':');
    if (sep < 1) return sendErr(errCodeIllegalArg);
    try {
      await bridge.setCustomVar(
          text.substring(0, sep), text.substring(sep + 1));
      sendOk();
    } on CompanionOperationError catch (e) {
      _sendOperationError(e);
    }
  }

  Future<void> _cmdSetOtherParams(Uint8List data) async {
    if (data.isEmpty) return sendErr(errCodeIllegalArg);
    try {
      await bridge.setOtherParams(
        manualAddContacts: data[0],
        telemetryModes: data.length >= 2 ? data[1] : null,
        advertLocPolicy: data.length >= 3 ? data[2] : null,
        multiAcks: data.length >= 4 ? data[3] : null,
      );
      sendOk();
    } on CompanionOperationError catch (e) {
      _sendOperationError(e);
    }
  }

  // -------------------------------------------------------------------------
  // Radio
  // -------------------------------------------------------------------------

  Future<void> _cmdSetRadioParams(Uint8List data) async {
    if (data.length < 10) return sendErr(errCodeIllegalArg);
    final reader = BufferReader(data);
    final freq = reader.readUInt32Le();
    final bw = reader.readUInt32Le();
    final sf = reader.readByte();
    final cr = reader.readByte();
    // Matches the firmware: frequency is in kHz, bandwidth in Hz.
    if (freq < 150000 || freq > 2500000) return sendErr(errCodeIllegalArg);
    if (bw < 7000 || bw > 500000) return sendErr(errCodeIllegalArg);
    if (sf < 5 || sf > 12 || cr < 5 || cr > 8) {
      return sendErr(errCodeIllegalArg);
    }
    bool? clientRepeat;
    if (data.length >= 11) {
      final repeat = data[10];
      if (repeat > 1) return sendErr(errCodeIllegalArg);
      clientRepeat = repeat == 1;
    }
    try {
      await bridge.setRadioParams(
        freq * 1000,
        bw,
        sf,
        cr,
        clientRepeat: clientRepeat,
      );
      sendOk();
    } on CompanionOperationError catch (e) {
      _sendOperationError(e);
    }
  }

  Future<void> _cmdSetTxPower(Uint8List data) async {
    if (data.isEmpty) return sendErr(errCodeIllegalArg);
    final power = data[0] >= 0x80 ? data[0] - 0x100 : data[0];
    try {
      await bridge.setTxPower(power);
      sendOk();
    } on CompanionOperationError catch (e) {
      _sendOperationError(e);
    }
  }

  Future<void> _cmdGetTuningParams() async {
    try {
      final params = await bridge.getTuningParams();
      final w = BufferWriter()
        ..writeByte(respCodeTuningParams)
        ..writeUInt32Le(params.rxDelayBaseMs)
        ..writeUInt32Le(params.airtimeFactorMs);
      _sendFrame(w.toBytes());
    } on CompanionOperationError catch (e) {
      _sendOperationError(e);
    }
  }

  Future<void> _cmdSetTuningParams(Uint8List data) async {
    if (data.length < 8) return sendErr(errCodeIllegalArg);
    final r = BufferReader(data);
    final rx = r.readUInt32Le();
    final af = r.readUInt32Le();
    try {
      await bridge.setTuningParams(rx, af);
      sendOk();
    } on CompanionOperationError catch (e) {
      _sendOperationError(e);
    }
  }

  Future<void> _cmdSetPathHashMode(Uint8List data) async {
    // [cmd][reserved=0][mode]
    if (data.length < 2 || data[0] != 0) return sendErr(errCodeIllegalArg);
    final mode = data[1];
    if (mode >= 3) return sendErr(errCodeIllegalArg);
    await bridge.setPathHashMode(mode);
    sendOk();
  }

  Future<void> _cmdRunCliCommand(Uint8List data) async {
    final lifecycleBefore = bridge.lifecycleGeneration;
    String text;
    try {
      text = await bridge.runCliCommandBytes(data);
    } on CompanionOperationError catch (e) {
      text = e.disabled
          ? 'Error: disabled'
          : switch (e.code) {
              errCodeFileIoError ||
              errCodeTableFull =>
                'Error: storage failure',
              errCodeBadState => 'Error: device unavailable',
              errCodeIllegalArg => 'Error: illegal argument',
              _ => 'Error: unsupported',
            };
    } catch (_) {
      text = 'Error: illegal argument';
    }
    if (bridge.lifecycleGeneration != lifecycleBefore) {
      _signBuffer.clear();
    }
    _sendFrame(Uint8List.fromList([
      respCodeCliReply,
      ..._boundedCliReply(utf8.encode(text)),
    ]));
  }

  List<int> _boundedCliReply(List<int> bytes) {
    if (bytes.length <= maxCompanionPayloadSize - 1) return bytes;
    var end = maxCompanionPayloadSize - 1 - 3;
    while (end > 0 && end < bytes.length && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return [...bytes.sublist(0, end), ...utf8.encode('...')];
  }

  // -------------------------------------------------------------------------
  // Contacts
  // -------------------------------------------------------------------------

  void _cmdGetContacts(Uint8List data) {
    final since = data.length >= 4 ? BufferReader(data).readUInt32Le() : 0;
    final contacts = bridge.getContacts(since: since);
    final start = BufferWriter()
      ..writeByte(respCodeContactsStart)
      ..writeUInt32Le(contacts.length);
    _sendFrame(start.toBytes());
    var mostRecent = 0;
    for (final c in contacts) {
      _sendFrame(_contactFrame(c));
      if (c.lastmod > mostRecent) mostRecent = c.lastmod;
    }
    final end = BufferWriter()
      ..writeByte(respCodeEndOfContacts)
      ..writeUInt32Le(mostRecent);
    _sendFrame(end.toBytes());
  }

  Uint8List _contactFrame(Contact c) {
    final pathLen = c.outPathLen < 0 ? 0xFF : c.outPathLen.clamp(0, 255);
    final w = BufferWriter()
      ..writeByte(respCodeContact)
      ..writeBytes(c.publicKey)
      ..writeByte(c.advType)
      ..writeByte(c.flags)
      ..writeByte(pathLen);
    w.writeBytesPadded(c.outPath, maxPathSize);
    w.writeCString(c.name, maxNameSize);
    w.writeUInt32Le(c.lastAdvertTimestamp);
    w.writeInt32Le((c.gpsLat * 1e6).round());
    w.writeInt32Le((c.gpsLon * 1e6).round());
    w.writeUInt32Le(c.lastmod);
    return w.toBytes();
  }

  void _cmdGetContactByKey(Uint8List data) {
    if (data.length < pubKeySize) return sendErr(errCodeIllegalArg);
    final c = bridge.getPersistentContactByKey(data.sublist(0, pubKeySize));
    if (c == null) return sendErr(errCodeNotFound);
    _sendFrame(_contactFrame(c));
  }

  Future<void> _cmdAddUpdateContact(Uint8List data) async {
    if (data.length < 36) return sendErr(errCodeIllegalArg);
    final pubkey = data.sublist(0, pubKeySize);
    final advType = data[32];
    final flags = data[33];
    final pathLenByte = data[34];
    final int outPathLen;
    if (pathLenByte == 0xFF) {
      outPathLen = -1;
    } else if (PathUtils.isValidPathLen(pathLenByte)) {
      outPathLen = pathLenByte;
    } else {
      return sendErr(errCodeIllegalArg);
    }
    final pathStart = 35;
    final pathEnd = pathStart + maxPathSize;
    var path = Uint8List(0);
    if (outPathLen >= 0) {
      final pathBytes = PathUtils.getByteLength(outPathLen);
      if (data.length < pathStart + pathBytes) {
        return sendErr(errCodeIllegalArg);
      }
      path = data.sublist(pathStart, pathStart + pathBytes);
    }
    final nameStart = pathEnd;
    final nameEnd = nameStart + maxNameSize;
    Uint8List nameRaw;
    if (data.length >= nameEnd) {
      nameRaw = data.sublist(nameStart, nameEnd);
    } else if (data.length > nameStart) {
      nameRaw = Uint8List.fromList([
        ...data.sublist(nameStart),
        ...List<int>.filled(nameEnd - data.length, 0)
      ]);
    } else {
      nameRaw = Uint8List(maxNameSize);
    }
    final name = decodeContactNameBytes(nameRaw);
    if (name == null) return sendErr(errCodeIllegalArg);

    var lastAdvert = 0;
    var lat = 0.0;
    var lon = 0.0;
    var lastmod = bridge.getTime();
    final hasGps = data.length >= nameEnd + 12;
    if (data.length >= nameEnd + 4) {
      lastAdvert = BufferReader(data.sublist(nameEnd)).readUInt32Le();
    }
    if (hasGps) {
      final r = BufferReader(data.sublist(nameEnd + 4));
      final latMicros = r.readInt32Le();
      final lonMicros = r.readInt32Le();
      if (!isValidAdvertCoordinateMicros(latMicros, lonMicros)) {
        return sendErr(errCodeIllegalArg);
      }
      lat = latMicros / 1e6;
      lon = lonMicros / 1e6;
    }
    if (data.length >= nameEnd + 16) {
      lastmod = BufferReader(data.sublist(nameEnd + 12)).readUInt32Le();
    }
    final contact = Contact(
      publicKey: Uint8List.fromList(pubkey),
      name: name,
      advType: advType,
      flags: flags,
      outPathLen: outPathLen,
      outPath: path,
      lastAdvertTimestamp: lastAdvert,
      lastmod: lastmod,
      gpsLat: lat,
      gpsLon: lon,
    );
    try {
      await bridge.addUpdateContact(contact, hasGps: hasGps);
      sendOk();
    } on CompanionOperationError catch (e) {
      _sendOperationError(e);
    }
  }

  Future<void> _cmdRemoveContact(Uint8List data) async {
    if (data.length < pubKeySize) return sendErr(errCodeIllegalArg);
    try {
      await bridge.removeContact(data.sublist(0, pubKeySize));
      sendOk();
    } on CompanionOperationError catch (e) {
      _sendOperationError(e);
    }
  }

  Future<void> _cmdResetPath(Uint8List data) async {
    if (data.length < pubKeySize) return sendErr(errCodeIllegalArg);
    try {
      await bridge.resetPath(data.sublist(0, pubKeySize));
      sendOk();
    } on CompanionOperationError catch (e) {
      _sendOperationError(e);
    }
  }

  // -------------------------------------------------------------------------
  // Channels
  // -------------------------------------------------------------------------

  void _cmdGetChannel(Uint8List data) {
    final fullList = data.isEmpty;
    final max = bridge.maxChannels;
    if (fullList) {
      for (var i = 0; i < max; i++) {
        _sendFrame(_channelFrame(i, bridge.getChannel(i)));
      }
      if (max == 0) _sendFrame(_channelFrame(0, null));
      return;
    }
    final idx = data[0];
    if (idx >= max) return sendErr(errCodeNotFound);
    _sendFrame(_channelFrame(idx, bridge.getChannel(idx)));
  }

  Uint8List _channelFrame(int idx, Channel? ch) {
    final w = BufferWriter()
      ..writeByte(respCodeChannelInfo)
      ..writeByte(idx);
    w.writeCString(ch?.name ?? '', maxNameSize);
    final secret = Uint8List(16);
    if (ch != null) {
      final s = ch.secret;
      secret.setRange(0, s.length.clamp(0, 16), s);
    }
    w.writeBytes(secret);
    return w.toBytes();
  }

  Future<void> _cmdSetChannel(Uint8List data) async {
    if (data.length < 34) return sendErr(errCodeIllegalArg);
    final idx = data[0];
    final nameRaw = data.sublist(1, 33);
    final name = String.fromCharCodes(nameRaw.takeWhile((b) => b != 0)).trim();
    Uint8List secret;
    if (data.length >= 65) {
      secret = data.sublist(33, 65);
    } else if (data.length >= 49) {
      secret = data.sublist(33, 49);
    } else {
      return sendErr(errCodeIllegalArg);
    }
    try {
      await bridge.setChannel(idx, name, Uint8List.fromList(secret));
      sendOk();
    } on CompanionOperationError catch (e) {
      _sendOperationError(e);
    }
  }

  // -------------------------------------------------------------------------
  // Advert
  // -------------------------------------------------------------------------

  Future<void> _cmdSendSelfAdvert(Uint8List data) async {
    // Pinned firmware: only an explicit byte 1 selects flood; absent/0 is
    // zero-hop.
    final flood = data.isNotEmpty && data[0] == 1;
    final ok = await bridge.advertise(flood: flood);
    ok ? sendOk() : sendErr(errCodeBadState);
  }

  Future<void> _cmdSetAdvertName(Uint8List data) async {
    if (data.isEmpty) return sendErr(errCodeIllegalArg);
    final name = decodeAdvertNameBytes(data);
    if (name == null) return sendErr(errCodeIllegalArg);
    try {
      await bridge.setAdvertName(name);
      sendOk();
    } on CompanionOperationError catch (e) {
      _sendOperationError(e);
    }
  }

  Future<void> _cmdSetAdvertLatLon(Uint8List data) async {
    if (data.length < 8) return sendErr(errCodeIllegalArg);
    final r = BufferReader(data);
    final latMicros = r.readInt32Le();
    final lonMicros = r.readInt32Le();
    if (!isValidAdvertCoordinateMicros(latMicros, lonMicros)) {
      return sendErr(errCodeIllegalArg);
    }
    try {
      await bridge.setAdvertLatLon(
        latMicros / 1e6,
        lonMicros / 1e6,
      );
      sendOk();
    } on CompanionOperationError catch (e) {
      _sendOperationError(e);
    }
  }

  // -------------------------------------------------------------------------
  // Messaging
  // -------------------------------------------------------------------------

  Future<void> _cmdSendTxt(Uint8List data) async {
    if (data.length < 12) return sendErr(errCodeIllegalArg);
    final r = BufferReader(data);
    final txtType = r.readByte();
    final attempt = r.readByte();
    final timestamp = r.readUInt32Le();
    final prefix = r.readBytes(6);
    final text = r.readCString();
    final contact = bridge.getContactByKeyPrefix(prefix);
    if (contact == null) return sendErr(errCodeNotFound);
    final result = await bridge.sendTextMessage(
      contact.publicKey,
      text,
      txtType: txtType,
      // The firmware uses the app's timestamp and attempt verbatim; the ACK
      // hash the client precomputes is derived from these exact bytes.
      attempt: attempt,
      timestamp: timestamp,
    );
    if (!result.success) return sendErr(errCodeBadState);
    final w = BufferWriter()
      ..writeByte(respCodeSent)
      ..writeByte(result.isFlood ? 1 : 0)
      ..writeUInt32Le(result.expectedAck ?? 0)
      ..writeUInt32Le(result.timeoutMs ?? 5000);
    _sendFrame(w.toBytes());
  }

  Future<void> _cmdSendChannelTxt(Uint8List data) async {
    if (data.length < 6) return sendErr(errCodeIllegalArg);
    final r = BufferReader(data);
    final txtType = r.readByte();
    final channelIdx = r.readByte();
    r.skipBytes(4); // timestamp
    final text = r.readCString();
    if (txtType != txtTypePlain) return sendErr(errCodeUnsupportedCmd);
    if (bridge.getChannel(channelIdx) == null) return sendErr(errCodeNotFound);
    sendOk();
    final ok = await bridge.sendChannelMessage(channelIdx, text);
    if (!ok) _log('channel message send failed for channel $channelIdx');
  }

  Future<void> _cmdSendChannelData(Uint8List data) async {
    // [channel_idx][path_len][path?][data_type u16 LE][payload...]
    if (data.length < 4) return sendErr(errCodeIllegalArg);
    final r = BufferReader(data);
    final channelIdx = r.readByte();
    final pathLen = r.readByte();
    if (pathLen != 0xFF && !PathUtils.isValidPathLen(pathLen)) {
      return sendErr(errCodeIllegalArg);
    }
    var pathBytes = const <int>[];
    if (pathLen != 0xFF) {
      final byteLen = PathUtils.getByteLength(pathLen);
      if (r.remaining < byteLen + 2) return sendErr(errCodeIllegalArg);
      pathBytes = r.readBytes(byteLen);
    }
    if (r.remaining < 2) return sendErr(errCodeIllegalArg);
    final dataType = r.readUInt16Le();
    final payload = r.readRemainingBytes();
    if (dataType == dataTypeReserved) return sendErr(errCodeIllegalArg);
    // The radio-side group-data limit is 165; the 167-byte channel-data limit
    // applies only to CHANNEL_DATA_RECV pushes. The whole command must also fit
    // the 176-byte companion payload, so a long path reduces the data budget.
    if (payload.length > maxGroupDataLength ||
        payload.length >
            maxGroupDataLengthForCompanionPath(pathBytes.length)) {
      return sendErr(errCodeIllegalArg);
    }
    final commandLength = 5 + pathBytes.length + payload.length;
    if (commandLength > maxCompanionPayloadSize) {
      return sendErr(errCodeIllegalArg);
    }
    if (bridge.getChannel(channelIdx) == null) return sendErr(errCodeNotFound);
    final ok = await bridge.sendChannelData(
      channelIdx,
      dataType,
      Uint8List.fromList(payload),
      path: pathBytes,
      pathLenEncoded: pathLen,
    );
    ok ? sendOk() : sendErr(errCodeTableFull);
  }

  Future<void> _cmdSendControlData(Uint8List data) async {
    // The first control byte must set the 0x80 bit (control-data marker).
    if (data.isEmpty || (data[0] & 0x80) == 0) {
      return sendErr(errCodeIllegalArg);
    }
    final ok = await bridge.sendControlData(data);
    ok ? sendOk() : sendErr(errCodeTableFull);
  }

  Future<void> _cmdSyncNextMessage() async {
    try {
      final msg = await bridge.syncNextMessage();
      if (msg == null) {
        _sendFrame(Uint8List.fromList([respCodeNoMoreMessages]));
        return;
      }
      _sendFrame(_messageFrame(msg));
    } on CompanionOperationError catch (e) {
      _sendOperationError(e);
    }
  }

  Uint8List _messageFrame(QueuedMessage msg) {
    var snrByte = (msg.snr * 4).round().clamp(-128, 127);
    if (snrByte < 0) snrByte += 256;
    final pathLenByte = msg.pathLen < 256 ? msg.pathLen : 0xFF;
    if (msg.isChannel) {
      if (msg.channelDataType != 0) {
        final raw = msg.channelDataPayload ?? Uint8List(0);
        final payload = raw.length > maxChannelDataLength
            ? raw.sublist(0, maxChannelDataLength)
            : raw;
        final w = BufferWriter()
          ..writeByte(respCodeChannelDataRecv)
          ..writeByte(snrByte & 0xFF)
          ..writeByte(0)
          ..writeByte(0)
          ..writeByte(msg.channelIdx)
          ..writeByte(pathLenByte)
          ..writeUInt16Le(msg.channelDataType & 0xFFFF)
          ..writeByte(payload.length)
          ..writeBytes(payload);
        return w.toBytes();
      }
      if (_appTargetVer >= 3) {
        final w = BufferWriter()
          ..writeByte(respCodeChannelMsgRecvV3)
          ..writeByte(snrByte & 0xFF)
          ..writeByte(0)
          ..writeByte(0)
          ..writeByte(msg.channelIdx)
          ..writeByte(pathLenByte)
          ..writeByte(msg.txtType)
          ..writeUInt32Le(msg.timestamp)
          ..writeString(msg.text);
        return w.toBytes();
      }
      final w = BufferWriter()
        ..writeByte(respCodeChannelMsgRecv)
        ..writeByte(msg.channelIdx)
        ..writeByte(pathLenByte)
        ..writeByte(msg.txtType)
        ..writeUInt32Le(msg.timestamp)
        ..writeString(msg.text);
      return w.toBytes();
    }
    final prefix = msg.senderKey.length >= 6
        ? msg.senderKey.sublist(0, 6)
        : Uint8List.fromList(
            [...msg.senderKey, ...List.filled(6 - msg.senderKey.length, 0)]);
    if (_appTargetVer >= 3) {
      final w = BufferWriter()
        ..writeByte(respCodeContactMsgRecvV3)
        ..writeByte(snrByte & 0xFF)
        ..writeByte(0)
        ..writeByte(0)
        ..writeBytes(prefix)
        ..writeByte(pathLenByte)
        ..writeByte(msg.txtType)
        ..writeUInt32Le(msg.timestamp)
        ..writeString(msg.text);
      return w.toBytes();
    }
    final w = BufferWriter()
      ..writeByte(respCodeContactMsgRecv)
      ..writeBytes(prefix)
      ..writeByte(pathLenByte)
      ..writeByte(msg.txtType)
      ..writeUInt32Le(msg.timestamp)
      ..writeString(msg.text);
    return w.toBytes();
  }

  // -------------------------------------------------------------------------
  // Signing
  // -------------------------------------------------------------------------

  void _cmdSignStart() {
    _signBuffer.clear();
    final w = BufferWriter()
      ..writeByte(respCodeSignStart)
      ..writeByte(0)
      ..writeUInt32Le(config.maxSignDataLen);
    _sendFrame(w.toBytes());
  }

  void _cmdSignData(Uint8List data) {
    if (data.isEmpty) return sendErr(errCodeIllegalArg);
    if (_signBuffer.length + data.length > config.maxSignDataLen) {
      return sendErr(errCodeTableFull);
    }
    _signBuffer.addAll(data);
    sendOk();
  }

  Future<void> _cmdSignFinish() async {
    try {
      final signature = await bridge.sign(Uint8List.fromList(_signBuffer));
      _signBuffer.clear();
      _sendFrame(
          Uint8List.fromList([respCodeSignature, ...signature.take(64)]));
    } catch (_) {
      sendErr(errCodeBadState);
    }
  }

  // -------------------------------------------------------------------------
  // Stats / advert path / export
  // -------------------------------------------------------------------------

  Future<void> _cmdExportPrivateKey() async {
    try {
      final key = await bridge.exportPrivateKey();
      if (key.length != 64) {
        _log('identity export returned an invalid length');
        return sendErr(errCodeBadState);
      }
      _sendFrame(Uint8List.fromList([respCodePrivateKey, ...key]));
    } on CompanionOperationError catch (e) {
      _sendOperationError(e);
    }
  }

  Future<void> _cmdImportPrivateKey(Uint8List data) async {
    // Firmware accepts len>=65 including the command byte and ignores trailing
    // bytes; a short key is never truncated or clamped into validity.
    if (data.length < 64) return sendErr(errCodeIllegalArg);
    final key = Uint8List.fromList(data.sublist(0, 64));
    try {
      await bridge.importPrivateKey(key);
      _signBuffer.clear();
      sendOk();
    } on CompanionOperationError catch (e) {
      _sendOperationError(e);
    }
  }

  Future<void> _cmdGetStats(Uint8List data) async {
    final statsType = data.isEmpty ? statsTypePackets : data[0];
    if (statsType != statsTypeCore &&
        statsType != statsTypeRadio &&
        statsType != statsTypePackets) {
      return sendErr(errCodeIllegalArg);
    }
    final stats = await bridge.getStats(statsType);
    final w = BufferWriter()
      ..writeByte(respCodeStats)
      ..writeByte(statsType);
    switch (statsType) {
      case statsTypeCore:
        w
          ..writeUInt16Le((stats['battery_mv'] as int?) ?? 0)
          ..writeUInt32Le((stats['uptime_secs'] as int?) ?? 0)
          ..writeUInt16Le((stats['errors'] as int?) ?? 0)
          ..writeByte(((stats['queue_len'] as int?) ?? 0).clamp(0, 255));
      case statsTypeRadio:
        w
          ..writeUInt16Le((stats['noise_floor'] as int?) ?? 0)
          ..writeByte(((stats['last_rssi'] as int?) ?? 0) & 0xFF)
          ..writeByte(((stats['last_snr_scaled'] as int?) ?? 0) & 0xFF)
          ..writeUInt32Le((stats['tx_air_secs'] as int?) ?? 0)
          ..writeUInt32Le((stats['rx_air_secs'] as int?) ?? 0);
      default:
        w
          ..writeUInt32Le((stats['recv'] as int?) ?? 0)
          ..writeUInt32Le((stats['sent'] as int?) ?? 0)
          ..writeUInt32Le((stats['flood_tx'] as int?) ?? 0)
          ..writeUInt32Le((stats['direct_tx'] as int?) ?? 0)
          ..writeUInt32Le((stats['flood_rx'] as int?) ?? 0)
          ..writeUInt32Le((stats['direct_rx'] as int?) ?? 0)
          ..writeUInt32Le((stats['recv_errors'] as int?) ?? 0);
    }
    _sendFrame(w.toBytes());
  }

  void _cmdGetAdvertPath(Uint8List data) {
    if (data.length < 1 + pubKeySize) return sendErr(errCodeIllegalArg);
    final pubkey = data.sublist(1, 1 + pubKeySize);
    final found = bridge.getAdvertPath(pubkey.sublist(0, 7));
    if (found == null) return sendErr(errCodeNotFound);
    final pathByteLen = PathUtils.getByteLength(found.pathLen);
    final w = BufferWriter()
      ..writeByte(respCodeAdvertPath)
      ..writeUInt32Le(found.recvTimestamp)
      ..writeByte(found.pathLen)
      ..writeBytes(found.path.take(pathByteLen).toList());
    _sendFrame(w.toBytes());
  }

  Future<void> _cmdExportContact(Uint8List data) async {
    final pubkey =
        data.length >= pubKeySize ? data.sublist(0, pubKeySize) : null;
    final raw = await bridge.exportContact(pubkey);
    if (raw == null) return sendErr(errCodeNotFound);
    _sendFrame(Uint8List.fromList([respCodeExportContact, ...raw]));
  }

  Future<void> _cmdImportContact(Uint8List data) async {
    if (data.isEmpty) return sendErr(errCodeIllegalArg);
    final ok = await bridge.importContact(Uint8List.fromList(data));
    ok ? sendOk() : sendErr(errCodeIllegalArg);
  }

  Future<void> _cmdShareContact(Uint8List data) async {
    if (data.length < pubKeySize) return sendErr(errCodeIllegalArg);
    final pubkey = Uint8List.fromList(data.sublist(0, pubKeySize));
    final ok = await bridge.shareContact(pubkey);
    ok ? sendOk() : sendErr(errCodeNotFound);
  }

  Future<void> _cmdSendBinaryReq(Uint8List data) async {
    if (data.length < 33) return sendErr(errCodeIllegalArg);
    final pubkey = data.sublist(0, pubKeySize);
    final reqData = data.sublist(pubKeySize);
    final result = await bridge.sendBinaryReq(pubkey, reqData);
    if (!result.success) return sendErr(errCodeNotFound);
    final w = BufferWriter()
      ..writeByte(respCodeSent)
      ..writeByte(result.isFlood ? 1 : 0)
      ..writeUInt32Le(result.expectedAck ?? 0)
      ..writeUInt32Le(result.timeoutMs ?? 10000);
    _sendFrame(w.toBytes());
  }

  Future<void> _cmdSendAnonReq(Uint8List data) async {
    // [pubkey(32)][anon_req_data...]
    if (data.length <= pubKeySize) return sendErr(errCodeIllegalArg);
    final pubkey = Uint8List.fromList(data.sublist(0, pubKeySize));
    final reqData = Uint8List.fromList(data.sublist(pubKeySize));
    final result = await bridge.sendAnonReq(pubkey, reqData);
    if (!result.success) return sendErr(errCodeNotFound);
    _sendSent(result);
  }

  Future<void> _cmdSendTelemetryReq(Uint8List data) async {
    // 'self' telemetry: the firmware accepts a 4-byte frame (command + 3 zero
    // bytes) and answers with the local node's own LPP telemetry. `data` here
    // excludes the command byte, so that is a 3-byte payload.
    if (data.length == 3) {
      final batt = await bridge.getBatteryAndStorage();
      final lpp = (BufferWriter()
            ..writeByte(telemChannelSelf)
            ..writeByte(0x74) // CayenneLPP voltage (0.01 V)
            ..writeUInt16Be((batt.millivolts / 10).round()))
          .toBytes();
      _sendFrame(Uint8List.fromList([
        pushCodeTelemetryResponse,
        0,
        ...bridge.getPublicKey().sublist(0, 6),
        ...lpp,
      ]));
      return;
    }
    if (data.length < 3 + pubKeySize) return sendErr(errCodeIllegalArg);
    final pubkey = Uint8List.fromList(data.sublist(3, 3 + pubKeySize));
    final result = await bridge.sendTelemetryRequest(pubkey);
    if (!result.success) return sendErr(errCodeNotFound);
    // The telemetry payload itself arrives later via PUSH_CODE_TELEMETRY_RESPONSE.
    _sendSent(result);
  }

  Future<void> _cmdSendRawData(Uint8List data) async {
    // [path_len][path bytes][payload (>=4)] — flood is not supported.
    if (data.isEmpty) return sendErr(errCodeIllegalArg);
    final pathLenByte = data[0];
    if (!PathUtils.isValidPathLen(pathLenByte)) {
      return sendErr(errCodeUnsupportedCmd);
    }
    final pathBytes = PathUtils.getByteLength(pathLenByte);
    if (data.length < 1 + pathBytes + 4) return sendErr(errCodeIllegalArg);
    final path = Uint8List.fromList(data.sublist(1, 1 + pathBytes));
    final payload = Uint8List.fromList(data.sublist(1 + pathBytes));
    final ok = await bridge.sendRawData(payload, path, pathLenByte);
    ok ? sendOk() : sendErr(errCodeTableFull);
  }

  Future<void> _cmdSendRawPacket(Uint8List data) async {
    // [priority][full packet bytes] — transmitted verbatim (route type and path
    // encoded in the packet header).
    if (data.length < 3) return sendErr(errCodeIllegalArg);
    final priority = data[0];
    final packet = Packet.readFrom(Uint8List.fromList(data.sublist(1)));
    if (packet == null) return sendErr(errCodeIllegalArg);
    final ok = await bridge.sendRawPacket(packet, priority);
    ok ? sendOk() : sendErr(errCodeTableFull);
  }

  Future<void> _cmdSendTracePath(Uint8List data) async {
    if (data.length < 10) return sendErr(errCodeIllegalArg);
    final r = BufferReader(data);
    final tag = r.readUInt32Le();
    final authCode = r.readUInt32Le();
    final flags = r.readByte();
    final pathBytes = r.readRemainingBytes();
    final pathLen = pathBytes.length;
    final pathSz = flags & 0x03;
    if ((pathLen >> pathSz) > maxPathSize || pathLen % (1 << pathSz) != 0) {
      return sendErr(errCodeIllegalArg);
    }
    final ok = await bridge.sendTracePathRaw(tag, authCode, flags, pathBytes);
    if (!ok) return sendErr(errCodeTableFull);
    final timeout = 5000 + pathLen * 200;
    final w = BufferWriter()
      ..writeByte(respCodeSent)
      ..writeByte(0)
      ..writeUInt32Le(tag)
      ..writeUInt32Le(timeout);
    _sendFrame(w.toBytes());
  }

  Future<void> _cmdSendPathDiscoveryReq(Uint8List data) async {
    // data = [request-index(0)] + pubkey(32); the index must be 0.
    if (data.length < 1 + pubKeySize || data[0] != 0) {
      return sendErr(errCodeIllegalArg);
    }
    final pubkey = Uint8List.fromList(data.sublist(1, 1 + pubKeySize));
    final result = await bridge.sendPathDiscoveryReq(pubkey);
    if (!result.success) return sendErr(errCodeNotFound);
    _sendSent(result);
  }

  Future<void> _cmdSendLogin(Uint8List data) async {
    if (data.length < pubKeySize) return sendErr(errCodeIllegalArg);
    final pubkey = Uint8List.fromList(data.sublist(0, pubKeySize));
    final password =
        String.fromCharCodes(data.sublist(pubKeySize).takeWhile((b) => b != 0));
    final result = await bridge.sendLogin(pubkey, password);
    if (!result.success) return sendErr(errCodeNotFound);
    _sendSent(result);
  }

  Future<void> _cmdSendStatusReq(Uint8List data) async {
    if (data.length < pubKeySize) return sendErr(errCodeIllegalArg);
    final pubkey = Uint8List.fromList(data.sublist(0, pubKeySize));
    final result = await bridge.sendStatusReq(pubkey);
    if (!result.success) return sendErr(errCodeNotFound);
    _sendSent(result);
  }

  void _cmdLogout(Uint8List data) {
    if (data.length < pubKeySize) return sendErr(errCodeIllegalArg);
    bridge.logout(Uint8List.fromList(data.sublist(0, pubKeySize)));
    sendOk();
  }

  void _cmdHasConnection(Uint8List data) {
    if (data.length < pubKeySize) return sendErr(errCodeIllegalArg);
    final pubkey = Uint8List.fromList(data.sublist(0, pubKeySize));
    bridge.hasConnection(pubkey) ? sendOk() : sendErr(errCodeNotFound);
  }

  void _cmdSetFloodScope(Uint8List data) {
    if (data.isEmpty) return sendErr(errCodeIllegalArg);
    switch (data[0]) {
      case 0: // set (or reset) the send-scope override
        if (data.length >= 1 + 16) {
          bridge.setFloodScopeKey(Uint8List.fromList(data.sublist(1, 1 + 16)));
        } else {
          bridge.setFloodScopeKey(null);
        }
        sendOk();
      case 1: // force unscoped flooding (fw v12+)
        bridge.setFloodUnscoped();
        sendOk();
      default:
        sendErr(errCodeIllegalArg);
    }
  }

  Future<void> _cmdSetDefaultFloodScope(Uint8List data) async {
    // [name(31)][key(16)] sets; anything shorter clears the default scope.
    try {
      if (data.length >= 31 + 16) {
        final nameBytes = data.sublist(0, 31);
        final end = nameBytes.indexOf(0);
        final name = String.fromCharCodes(
            end >= 0 ? nameBytes.sublist(0, end) : nameBytes);
        if (name.isEmpty || name.length >= 31) {
          return sendErr(errCodeIllegalArg);
        }
        await bridge.setDefaultFloodScope(
            name, Uint8List.fromList(data.sublist(31, 31 + 16)));
      } else {
        await bridge.setDefaultFloodScope('', null);
      }
      sendOk();
    } on CompanionOperationError catch (e) {
      _sendOperationError(e);
    }
  }

  Future<void> _cmdGetAllowedRepeatFreq() async {
    try {
      final ranges = await bridge.getAllowedRepeatFreq();
      _sendFrame(Uint8List.fromList([respCodeAllowedRepeatFreq, ...ranges]));
    } on CompanionOperationError catch (e) {
      _sendOperationError(e);
    }
  }

  void _cmdGetDefaultFloodScope() {
    final (name, key) = bridge.getDefaultFloodScope();
    if (name.isEmpty || key == null) {
      return _sendFrame(Uint8List.fromList([respCodeDefaultFloodScope]));
    }
    final w = BufferWriter()
      ..writeByte(respCodeDefaultFloodScope)
      ..writeCString(name, 31)
      ..writeBytes(key);
    _sendFrame(w.toBytes());
  }

  /// Clear the current client's partial SIGN_START/DATA buffer after an
  /// app-only virtual reset or identity/lifecycle change.
  void clearSigningBuffer() => _signBuffer.clear();

  Future<void> _cmdReboot(Uint8List data) async {
    // Exact magic only; extra bytes are not a reboot alias.
    if (data.length != 6 || String.fromCharCodes(data) != 'reboot') {
      return sendErr(errCodeIllegalArg);
    }
    await bridge.reboot();
    _signBuffer.clear();
    sendOk();
  }

  void _sendSent(SentResult result) {
    final w = BufferWriter()
      ..writeByte(respCodeSent)
      ..writeByte(result.isFlood ? 1 : 0)
      ..writeUInt32Le(result.expectedAck ?? 0)
      ..writeUInt32Le(result.timeoutMs ?? 10000);
    _sendFrame(w.toBytes());
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  void _writeFixedString(BufferWriter w, String value, int length) {
    w.writeCString(value, length);
  }

  void _log(String message) => onLog?.call('[CompanionServer] $message');
}

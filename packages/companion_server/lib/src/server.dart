import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

import 'bridge.dart';
import 'command_dispatcher.dart';
import 'command_spec.dart';
import 'metrics.dart';
import 'push_codec.dart';

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
class CompanionServer implements CompanionPushSink, CompanionCommandHost {
  CompanionServer({
    required CompanionBridge bridge,
    this.config = const CompanionServerConfig(),
    this.onLog,
    CompanionMetrics? metrics,
    this.timerFactory,
    this.periodicTimerFactory,
  })  : _bridge = bridge,
        metrics = metrics ?? CompanionMetrics();

  CompanionBridge _bridge;

  /// The bridge currently bound to the app-facing session.
  @override
  CompanionBridge get bridge => _bridge;

  final CompanionServerConfig config;
  final void Function(String message)? onLog;

  /// Optional timer sources for deterministic lifecycle tests.
  final Timer Function(Duration duration, void Function() callback)?
      timerFactory;
  final Timer Function(
    Duration duration,
    void Function(Timer timer) callback,
  )? periodicTimerFactory;

  /// Session-only client traffic counters. The app may retain this object
  /// across proxy restarts so its totals survive a stop/start.
  @override
  final CompanionMetrics metrics;

  ServerSocket? _server;
  Socket? _client;
  // The app-facing server only accepts app→radio ('<') frames.
  final SerialFrameCodec _codec =
      SerialFrameCodec(direction: FrameDirection.inbound);
  Timer? _idleTimer;
  Timer? _heartbeatTimer;

  /// Protocol version reported by the current client, from the shared counter
  /// object so diagnostics and framing cannot disagree.
  @override
  int get appTargetVer => metrics.appTargetVer ?? 0;

  @override
  int get maxSignDataLen => config.maxSignDataLen;

  late final CompanionCommandDispatcher _commands =
      CompanionCommandDispatcher(this);

  /// The declared command table, keyed by command code.
  Map<int, CommandSpec> get commandSpecs => _commands.commands;

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
    log('listening on ${config.bindAddress}:${server.port}');
    server.listen(
      _handleClient,
      onError: (Object e) => log('server error: $e'),
    );
  }

  Future<void> stop() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    _disconnectClient(reason: 'server stop');
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
        _bridge.setPushSink(_client == null ? null : this);
      } finally {
        _switchingBridge = false;
        if (!completer.isCompleted) completer.complete();
      }
    }).catchError((Object e) {
      _switchingBridge = false;
      log('bridge switch error: $e');
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }

  // -------------------------------------------------------------------------
  // Client lifecycle
  // -------------------------------------------------------------------------

  void _handleClient(Socket socket) {
    log('client connected from ${socket.remoteAddress.address}');
    if (_client != null) {
      log('evicting previous client');
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
    _commands.resetClientState();
    socket.setOption(SocketOption.tcpNoDelay, true);
    // During a bridge switch the new bridge is installed by the barrier; the
    // old bridge must not receive a new client's push sink in the meantime.
    if (!_switchingBridge) _bridge.setPushSink(this);
    metrics.appTargetVersionReset();

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
        log('client error: $e');
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
      log('command queue error: $e');
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
    _commands.resetClientState();
    if (client != null) {
      metrics.clientDisconnected(reason,
          error: error, idleTimeout: idleTimeout);
    }
    log('client disconnected: $reason');
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
    _idleTimer = (timerFactory ?? Timer.new)(
      config.clientIdleTimeout,
      () => _disconnectClient(reason: 'idle timeout', idleTimeout: true),
    );
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    if (config.heartbeatInterval <= Duration.zero) return;
    _heartbeatTimer = (periodicTimerFactory ?? Timer.periodic)(
      config.heartbeatInterval,
      (_) => _sendPushFrame(encodeCurrTime(bridge.getTime())),
    );
  }

  // -------------------------------------------------------------------------
  // Frame I/O
  // -------------------------------------------------------------------------

  /// Send a command reply. Replies from an older client generation are dropped.
  @override
  void sendFrame(List<int> payload,
      {bool error = false, bool disabled = false}) {
    final generation = _commandGeneration;
    if (generation != null && generation != _connectionGeneration) {
      log('dropping reply from evicted client generation $generation');
      return;
    }
    _writeTo(_client, payload, push: false, error: error, disabled: disabled);
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
    bool disabled = false,
  }) {
    if (client == null) return;
    try {
      client.add(_codec.encodeFrame(payload));
      if (push) {
        metrics.pushSent(payload.length);
      } else {
        metrics.replyFrameSent(payload.length);
        if (error) metrics.errorReplyFrameSent();
        if (disabled) metrics.disabledReplyFrameSent();
      }
    } catch (e) {
      metrics.writeFailed();
      log('write failed: $e');
      if (identical(client, _client)) {
        _disconnectClient(reason: 'write failed', error: true);
      }
    }
  }

  @override
  void sendOk() => sendFrame(Uint8List.fromList([respCodeOk]));

  @override
  void sendErr(int code) =>
      sendFrame(Uint8List.fromList([respCodeErr, code]), error: true);

  @override
  void sendDisabled() =>
      sendFrame(Uint8List.fromList([respCodeDisabled]), disabled: true);

  // -------------------------------------------------------------------------
  // Push sink
  // -------------------------------------------------------------------------

  @override
  void pushMsgWaiting() => _sendPushFrame(encodePushMsgWaiting());

  @override
  void pushSendConfirmed(int ackCrc, {int tripTimeMs = 0}) => _sendPushFrame(
        encodePushSendConfirmed(ackCrc, tripTimeMs: tripTimeMs),
      );

  @override
  void pushAdvert(Uint8List pubkey) => _sendPushFrame(encodePushAdvert(pubkey));

  @override
  void pushNewAdvert(Uint8List contactFrame) =>
      _sendPushFrame(encodePushNewAdvert(contactFrame));

  @override
  void pushContactDeleted(Uint8List pubkey) =>
      _sendPushFrame(encodePushContactDeleted(pubkey));

  @override
  void pushContactsFull() => _sendPushFrame(encodePushContactsFull());

  @override
  void pushPathUpdated(Uint8List pubkey) =>
      _sendPushFrame(encodePushPathUpdated(pubkey));

  @override
  void pushTelemetryResponse(Uint8List pubkeyPrefix6, Uint8List data) =>
      _sendPushFrame(encodePushTelemetryResponse(pubkeyPrefix6, data));

  @override
  void pushBinaryResponse(int tag, Uint8List data) =>
      _sendPushFrame(encodePushBinaryResponse(tag, data));

  @override
  void pushRawRxData(double snr, int rssi, Uint8List raw) =>
      _sendPushFrame(encodePushRawRxData(snr, rssi, raw));

  @override
  void pushRawData(double snr, int rssi, Uint8List payload) =>
      _sendPushFrame(encodePushRawData(snr, rssi, payload));

  @override
  void pushPathDiscoveryResponse(Uint8List pubkeyPrefix6, int outPathLen,
          Uint8List outPath, int inPathLen, Uint8List inPath) =>
      _sendPushFrame(encodePushPathDiscoveryResponse(
        pubkeyPrefix6,
        outPathLen,
        outPath,
        inPathLen,
        inPath,
      ));

  @override
  void pushLoginSuccess(
    Uint8List pubkeyPrefix6, {
    bool legacy = false,
    int permissions = 0,
    int serverTag = 0,
    int acl = 0,
    int firmwareVer = 0,
  }) =>
      _sendPushFrame(encodePushLoginSuccess(
        pubkeyPrefix6,
        legacy: legacy,
        permissions: permissions,
        serverTag: serverTag,
        acl: acl,
        firmwareVer: firmwareVer,
      ));

  @override
  void pushLoginFail(Uint8List pubkeyPrefix6) =>
      _sendPushFrame(encodePushLoginFail(pubkeyPrefix6));

  @override
  void pushStatusResponse(Uint8List pubkeyPrefix6, Uint8List data) =>
      _sendPushFrame(encodePushStatusResponse(pubkeyPrefix6, data));

  @override
  void pushControlData(double snr, int rssi, int pathLen, Uint8List data) =>
      _sendPushFrame(encodePushControlData(snr, rssi, pathLen, data));

  @override
  void pushTraceData(
    int pathLen,
    int flags,
    int tag,
    int authCode,
    Uint8List pathHashes,
    Uint8List pathSnrs,
    int finalSnrByte,
  ) =>
      _sendPushFrame(encodePushTraceData(
        pathLen,
        flags,
        tag,
        authCode,
        pathHashes,
        pathSnrs,
        finalSnrByte,
      ));

  // -------------------------------------------------------------------------
  // Command dispatch
  // -------------------------------------------------------------------------

  Future<void> _handleCommand(Uint8List payload) async =>
      _commands.handle(payload);

  /// Clear the current client's partial SIGN_START/DATA buffer after an
  /// app-only virtual reset or identity/lifecycle change.
  void clearSigningBuffer() => _commands.clearSigningBuffer();

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  @override
  void log(String message) => onLog?.call('[CompanionServer] $message');
}

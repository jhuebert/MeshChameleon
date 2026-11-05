// Live Linux recovery test against a real TCP companion.
//
//   flutter test integration_test/connection_recovery_test.dart -d linux \
//     --dart-define=DEVICE_HOST=<companion-host> \
//     [--dart-define=DEVICE_PORT=5000] \
//     [--dart-define=PEER_HOST=<peer-companion-host>] \
//     [--dart-define=PEER_PORT=5000] \
//     [--dart-define=CHANNEL_PSK_HEX=<32-hex-char channel PSK>] \
//     [--dart-define=CHANNEL_NAME=#chameleon]
//
// The test drives the real AppState/recovery state machine through a local TCP
// relay it can start and stop. Stopping the relay models the companion vanishing;
// starting it again models the radio coming back. A second companion can send a
// group message on the shared channel (only when PEER_HOST and CHANNEL_PSK_HEX
// are supplied) so the queue-while-disconnected behavior is exercised too.
//
// This is Linux-only: BLE autoConnect and the Android foreground service still
// need hardware validation.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/main.dart';
import 'package:meshchameleon/screens/connect_screen.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/foreground_service.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/network_connection_store.dart';
import 'package:meshchameleon/services/session_store.dart';
import 'package:provider/provider.dart';
import 'package:test_support/test_support.dart' as support;

const _deviceHost = String.fromEnvironment('DEVICE_HOST');
const _devicePort = int.fromEnvironment('DEVICE_PORT', defaultValue: 5000);
const _peerHost = String.fromEnvironment('PEER_HOST');
const _peerPort = int.fromEnvironment('PEER_PORT', defaultValue: 5000);
const _channelName =
    String.fromEnvironment('CHANNEL_NAME', defaultValue: '#chameleon');
const _channelPskHex = String.fromEnvironment('CHANNEL_PSK_HEX');

/// A loopback TCP relay in front of the real companion.
///
/// The test owns its lifetime: [stop] closes the listener and every pipe (the
/// app sees a dropped link and refused reconnects); [start] brings it back on
/// the same port so the saved session target stays valid. [dropConnections]
/// resets only the live sockets, leaving the relay reachable, to model a brief
/// transport reset that the active reconnect grace period should absorb.
class _Relay {
  _Relay({required this.upstreamHost, required this.upstreamPort});

  final String upstreamHost;
  final int upstreamPort;

  ServerSocket? _server;
  StreamSubscription<Socket>? _subscription;
  final Set<_Pipe> _pipes = {};
  int? _port;

  int get port => _port ?? (throw StateError('relay has not started'));
  bool get listening => _server != null;

  Future<int> start() async {
    final existing = _server;
    if (existing != null) return existing.port;
    final preferred = _port;
    ServerSocket server;
    try {
      server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        preferred ?? 0,
      );
    } on SocketException {
      // A just-closed listener can still be in TIME_WAIT on some kernels.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        preferred ?? 0,
      );
    }
    _server = server;
    _port = server.port;
    _subscription = server.listen(_accept);
    return server.port;
  }

  Future<void> _accept(Socket client) async {
    if (_server == null) {
      client.destroy();
      return;
    }
    Socket upstream;
    try {
      upstream = await Socket.connect(
        upstreamHost,
        upstreamPort,
        timeout: const Duration(seconds: 5),
      );
    } catch (_) {
      client.destroy();
      return;
    }
    if (_server == null) {
      client.destroy();
      upstream.destroy();
      return;
    }
    final pipe = _Pipe(client, upstream);
    _pipes.add(pipe);
    pipe.start(onDone: () => _pipes.remove(pipe));
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    await server?.close();
    dropConnections();
  }

  void dropConnections() {
    for (final pipe in List.of(_pipes)) {
      pipe.close();
    }
    _pipes.clear();
  }
}

class _Pipe {
  _Pipe(this.client, this.device);

  final Socket client;
  final Socket device;
  bool _closed = false;

  void start({required void Function() onDone}) {
    client.setOption(SocketOption.tcpNoDelay, true);
    device.setOption(SocketOption.tcpNoDelay, true);
    void finish() {
      close();
      onDone();
    }

    client.listen(
      (data) => _write(device, data),
      onDone: finish,
      onError: (_) => finish(),
      cancelOnError: true,
    );
    device.listen(
      (data) => _write(client, data),
      onDone: finish,
      onError: (_) => finish(),
      cancelOnError: true,
    );
  }

  void _write(Socket socket, List<int> data) {
    if (_closed) return;
    try {
      socket.add(data);
    } catch (_) {
      close();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    client.destroy();
    device.destroy();
  }
}

/// Records requested recovery delays and optionally compresses them.
///
/// [requested] keeps the exact production durations, so a test can assert the
/// 30 s / 1 min / 2 min / 5 min / 10 min / 15 min schedule even when it runs the
/// timers faster. [holdPassive] models a foreground-nudge test where the timer
/// exists but never fires on its own.
class _Timers {
  _Timers({this.divisor = 1, this.holdPassive = false});

  final int divisor;
  final bool holdPassive;
  final List<Duration> requested = [];
  final Set<Timer> _live = {};

  Timer create(Duration duration, void Function() callback) {
    requested.add(duration);
    var effective = duration;
    if (holdPassive && duration >= const Duration(seconds: 30)) {
      effective = const Duration(hours: 1);
    } else if (divisor > 1) {
      effective = Duration(
        milliseconds: max(20, duration.inMilliseconds ~/ divisor),
      );
    }
    late final Timer timer;
    timer = Timer(effective, () {
      _live.remove(timer);
      callback();
    });
    _live.add(timer);
    return timer;
  }

  List<Duration> get passiveRequests =>
      requested.where((d) => d >= const Duration(seconds: 30)).toList();

  void cancelAll() {
    for (final timer in List.of(_live)) {
      timer.cancel();
    }
    _live.clear();
  }
}

class _RecordingForegroundService extends ForegroundService {
  final List<String> events = [];
  bool started = false;

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> start({required String title, required String text}) async {
    events.add('start|$title|$text');
    started = true;
  }

  @override
  Future<void> update({required String title, required String text}) async {
    events.add('update|$title|$text');
  }

  @override
  Future<void> stop() async {
    events.add('stop');
    started = false;
  }

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => true;

  @override
  Future<bool> openBatteryOptimizationSettings() async => true;

  String? get lastTitle {
    for (final event in events.reversed) {
      if (event.startsWith('start|') || event.startsWith('update|')) {
        return event.split('|')[1];
      }
    }
    return null;
  }

  bool get stoppedAfterLastStart {
    final start = events.lastIndexWhere((e) => e.startsWith('start|'));
    return start >= 0 && events.indexOf('stop', start) >= 0;
  }
}

class _Client {
  _Client(this._socket) {
    _socket.listen(
      (data) {
        for (final frame in _codec.ingest(data)) {
          _queue.add(frame);
        }
      },
      onError: (Object error) {
        _closed = true;
        if (!_queue.isClosed) _queue.close();
      },
      onDone: () {
        _closed = true;
        if (!_queue.isClosed) _queue.close();
      },
      cancelOnError: true,
    );
  }

  final Socket _socket;
  final SerialFrameCodec _codec = SerialFrameCodec.bidirectional();
  final StreamController<Uint8List> _queue =
      StreamController<Uint8List>.broadcast();
  late final support.StreamQueue<Uint8List> _frames =
      support.StreamQueue(_queue.stream);
  bool _closed = false;

  void send(List<int> payload) =>
      _socket.add(_codec.encodeFrame(payload, prefix: frameInboundPrefix));

  Future<Uint8List> next({
    bool pushes = false,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException('no frame within $timeout', timeout);
      }
      final frame = await _frames.nextWithin(remaining);
      if (frame == null) {
        if (_closed) throw StateError('companion client socket closed');
        throw TimeoutException('no frame within $timeout', timeout);
      }
      if (frame.isNotEmpty && frame[0] >= 0x80 && !pushes) continue;
      return frame;
    }
  }

  Future<Uint8List> command(List<int> payload) async {
    send(payload);
    return next();
  }

  Future<void> close() async {
    await _socket.close();
    if (!_queue.isClosed) await _queue.close();
  }

  Future<void> handshake() async {
    expect((await command([cmdDeviceQuery, appProtocolVersion]))[0],
        respCodeDeviceInfo);
    send([
      cmdAppStart,
      appProtocolVersion,
      0,
      0,
      0,
      0,
      0,
      0,
      ...utf8.encode('RECOVERY-TEST'),
      0,
    ]);
    final frame = await next();
    expect(frame[0], respCodeSelfInfo);
  }
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'condition not met before $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// Wait for the notification copy to catch up with an async state transition.
Future<void> _waitForTitle(
  _RecordingForegroundService foreground,
  String title, {
  Duration timeout = const Duration(seconds: 3),
}) =>
    _waitFor(
      () => foreground.lastTitle == title,
      timeout: timeout,
      reason:
          'notification did not reach "$title" (last=${foreground.lastTitle})'
          '\n${foreground.events.join('\n')}',
    );

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'condition not met before $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await Future<void>.delayed(const Duration(milliseconds: 250));
  await tester.pumpAndSettle();
}

Future<bool> _portOpen(int port) async {
  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(milliseconds: 400),
    );
    // Attach handlers before destroying: a connect/close race otherwise emits
    // an unhandled socket error that fails the surrounding test.
    socket.listen(
      (_) {},
      onError: (_) {},
      onDone: () {},
      cancelOnError: true,
    );
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

Future<int> _freePort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

/// Pick a free port, persist it as the proxy port, and start the proxy.
///
/// The real UI saves the port before starting, so this keeps the persisted
/// session and the live listener in agreement (the recovery restore reuses the
/// saved port).
Future<int> _startProxy(AppState app) async {
  final port = await _freePort();
  expect(await app.setProxyPort(port), isTrue, reason: app.logs.join('\n'));
  await app.startProxy();
  expect(app.proxyStatus, ProxyStatus.running, reason: app.logs.join('\n'));
  expect(app.port, port);
  return port;
}

AppState _buildApp(
  Directory dir, {
  required _Timers timers,
  required _RecordingForegroundService foreground,
  Duration reconnectDelay = const Duration(milliseconds: 300),
  TcpDeviceLinkFactory? tcpLinkFactory,
}) =>
    AppState(
      repository: IdentityRepository(
        supportDirectory: dir,
        secureStore: IdentityStore(),
      ),
      sessionStore: SessionStore(file: File('${dir.path}/session.json')),
      networkConnectionStore:
          NetworkConnectionStore(file: File('${dir.path}/history.json')),
      capabilities: const DeviceCapabilities(supportsBle: false),
      reconnectDelay: reconnectDelay,
      recoveryTimerFactory: timers.create,
      foregroundService: foreground,
      tcpLinkFactory: tcpLinkFactory,
    );

Future<void> _disposeApp(AppState app) async {
  await app.disconnectDevice();
  await app.manager?.dispose();
  app.dispose();
}

Future<void> _writeSession(Directory dir, SessionConfig config) async {
  await File('${dir.path}/session.json').writeAsString(
    jsonEncode(config.toJson()),
  );
}

Future<Map<String, dynamic>> _readSession(Directory dir) async {
  final file = File('${dir.path}/session.json');
  if (!await file.exists()) return const {};
  return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
}

Future<void> _attachViaRelay(AppState app, _Relay relay) async {
  await relay.start();
  final ok = await app.connectTcp(
    host: InternetAddress.loopbackIPv4.address,
    tcpPort: relay.port,
  );
  expect(ok, isTrue, reason: app.logs.join('\n'));
  expect(app.deviceConnected, isTrue, reason: app.logs.join('\n'));
}

/// Send one #chameleon group text from the peer companion over the air.
Future<void> _sendPeerChannelText(String marker) async {
  if (_peerHost.isEmpty || _channelPskHex.isEmpty) return;
  final peer = TcpDeviceLink(host: _peerHost, port: _peerPort);
  try {
    await peer.connect();
    final channel = Channel(
      name: _channelName,
      secret: _hex(_channelPskHex),
    );
    final packet = PacketBuilder.createGroupText(
      channel: channel,
      message: marker,
      senderName: 'RecoveryPeer',
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    await peer.sendRawPacket(packet.writeTo());
  } finally {
    await peer.disconnect();
  }
}

/// Wait for a queued group message across syncs and return its frame.
Future<Uint8List?> _syncUntilMarker(
  _Client client,
  String marker, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final frame = await client.command([cmdSyncNextMessage]);
    if (frame.isEmpty) continue;
    if (frame[0] == respCodeNoMoreMessages) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      continue;
    }
    final text = String.fromCharCodes(frame);
    if (text.contains(marker)) return frame;
  }
  return null;
}

Uint8List _hex(String input) => Uint8List.fromList([
      for (var i = 0; i < input.length; i += 2)
        int.parse(input.substring(i, i + 2), radix: 16),
    ]);

Future<void> _configureChannel(_Client client) async {
  if (_channelPskHex.isEmpty) return;
  final name = Uint8List(32);
  final encoded = utf8.encode(_channelName);
  name.setRange(0, encoded.length.clamp(0, 31), encoded);
  final reply = await client.command([
    cmdSetChannel,
    0,
    ...name,
    ..._hex(_channelPskHex),
  ]);
  expect(reply[0], respCodeOk);
  final info = await client.command([cmdGetChannel, 0]);
  expect(info[0], respCodeChannelInfo);
  expect(String.fromCharCodes(info.sublist(2, 34)), contains(_channelName));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('a short transport drop reconnects without disturbing the client',
      (tester) async {
    expect(_deviceHost, isNotEmpty, reason: 'Set DEVICE_HOST.');
    final dir = await Directory.systemTemp.createTemp('mc_recovery_short_');
    final relay = _Relay(upstreamHost: _deviceHost, upstreamPort: _devicePort);
    final timers = _Timers();
    final foreground = _RecordingForegroundService();
    final app = _buildApp(dir, timers: timers, foreground: foreground);
    _Client? client;
    addTearDown(() async {
      await client?.close();
      await _disposeApp(app);
      timers.cancelAll();
      await relay.stop();
      await dir.delete(recursive: true);
    });

    await app.loadIdentities();
    await _attachViaRelay(app, relay);
    final proxyPort = await _startProxy(app);
    client = _Client(await Socket.connect('127.0.0.1', proxyPort));
    await client.handshake();

    relay.dropConnections();
    await _waitFor(() => app.deviceReconnecting,
        timeout: const Duration(seconds: 5),
        reason: 'drop did not enter reconnecting:\n${app.logs.join('\n')}');
    expect(app.proxyStatus, ProxyStatus.running);
    expect((await client.command([cmdGetDeviceTime]))[0], respCodeCurrTime);

    await _waitFor(() => app.deviceConnected,
        timeout: const Duration(seconds: 10),
        reason: 'short drop did not reconnect:\n${app.logs.join('\n')}');
    expect(app.reconnectAttempts, greaterThanOrEqualTo(1));
    expect(app.reconnectSuccesses, greaterThanOrEqualTo(1));
    expect(app.port, proxyPort);
    expect(app.proxyStatus, ProxyStatus.running);
    expect((await client.command([cmdGetDeviceTime]))[0], respCodeCurrTime);
    expect(
        foreground.events.any((e) => e.contains('Reconnecting to companion')),
        isTrue,
        reason: foreground.events.join('\n'));
    await _waitForTitle(foreground, 'Proxy running');
    expect(timers.passiveRequests, isEmpty);
    expect(
      foreground.events.firstWhere((e) => e.startsWith('start|')),
      contains('Connecting to companion'),
      reason: 'the service did not start before the physical connect',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('a drop that outlives one retry cycle still recovers in grace',
      (tester) async {
    expect(_deviceHost, isNotEmpty, reason: 'Set DEVICE_HOST.');
    final dir = await Directory.systemTemp.createTemp('mc_recovery_grace_');
    final relay = _Relay(upstreamHost: _deviceHost, upstreamPort: _devicePort);
    final timers = _Timers();
    final foreground = _RecordingForegroundService();
    final app = _buildApp(dir, timers: timers, foreground: foreground);
    addTearDown(() async {
      await _disposeApp(app);
      timers.cancelAll();
      await relay.stop();
      await dir.delete(recursive: true);
    });

    await app.loadIdentities();
    await _attachViaRelay(app, relay);
    final proxyPort = await _startProxy(app);
    await relay.stop();
    await _waitFor(() => app.deviceReconnecting,
        timeout: const Duration(seconds: 8),
        reason: 'did not enter reconnecting:\n${app.logs.join('\n')}');
    // Keep the companion down across the first backoff cycle (three attempts
    // with 1 s / 2 s gaps), then return it during the next cycle.
    await Future<void>.delayed(const Duration(seconds: 4));
    await relay.start();
    await _waitFor(() => app.deviceConnected,
        timeout: const Duration(seconds: 15),
        reason: 'did not recover within the grace period:\n'
            '${app.logs.join('\n')}');
    expect(app.proxyStatus, ProxyStatus.running);
    expect(app.port, proxyPort);
    expect(app.reconnectAttempts, greaterThanOrEqualTo(2));
    expect(app.reconnectSuccesses, greaterThanOrEqualTo(1));
    expect(timers.passiveRequests, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('Cancel during a reconnect returns to idle and leaves no timer',
      (tester) async {
    expect(_deviceHost, isNotEmpty, reason: 'Set DEVICE_HOST.');
    final dir = await Directory.systemTemp.createTemp('mc_recovery_cancel_rc_');
    final relay = _Relay(upstreamHost: _deviceHost, upstreamPort: _devicePort);
    final timers = _Timers();
    final foreground = _RecordingForegroundService();
    final app = _buildApp(dir, timers: timers, foreground: foreground);
    addTearDown(() async {
      await _disposeApp(app);
      timers.cancelAll();
      await relay.stop();
      await dir.delete(recursive: true);
    });

    await app.loadIdentities();
    await _attachViaRelay(app, relay);
    final proxyPort = await _startProxy(app);
    final saved = app.lastSession;
    await relay.stop();
    await _waitFor(() => app.deviceReconnecting,
        timeout: const Duration(seconds: 8),
        reason: 'did not enter reconnecting:\n${app.logs.join('\n')}');

    await app.cancelDeviceAttempt();
    expect(app.devicePhase, DeviceLinkPhase.idle);
    expect(app.proxyStatus, ProxyStatus.stopped);
    expect(await _portOpen(proxyPort), isFalse);
    expect(app.recoveryPending, isFalse);
    expect(app.lastSession?.host, saved?.host);
    expect(app.lastSession?.devicePort, saved?.devicePort);
    expect(timers.passiveRequests, isEmpty);
    expect(foreground.stoppedAfterLastStart, isTrue);

    await relay.start();
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(app.devicePhase, DeviceLinkPhase.idle,
        reason: 'a canceled reconnect resumed on its own');
    expect(timers.passiveRequests, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets(
      'a long outage parks, then the real 30 s retry restores the session',
      (tester) async {
    expect(_deviceHost, isNotEmpty, reason: 'Set DEVICE_HOST.');
    final dir = await Directory.systemTemp.createTemp('mc_recovery_long_');
    final relay = _Relay(upstreamHost: _deviceHost, upstreamPort: _devicePort);
    final timers = _Timers();
    final foreground = _RecordingForegroundService();
    final app = _buildApp(dir, timers: timers, foreground: foreground);
    _Client? graceClient;
    _Client? restoredClient;
    addTearDown(() async {
      await graceClient?.close();
      await restoredClient?.close();
      await _disposeApp(app);
      timers.cancelAll();
      await relay.stop();
      await dir.delete(recursive: true);
    });

    await app.loadIdentities();
    await _attachViaRelay(app, relay);
    final proxyPort = await _startProxy(app);
    final identityKey = app.identity!.publicKey;

    var client = _Client(await Socket.connect('127.0.0.1', proxyPort));
    await client.handshake();
    final rename = await client.command([
      cmdSetAdvertName,
      ...utf8.encode('Recovery Virtual'),
      0,
    ]);
    expect(rename[0], respCodeOk);
    await _configureChannel(client);

    // Receive while no client is attached: the virtual node is still live and
    // must queue the group message.
    if (_peerHost.isNotEmpty && _channelPskHex.isNotEmpty) {
      await client.close();
      client = _Client(await Socket.connect('127.0.0.1', proxyPort));
      await client.handshake();
      await _sendPeerChannelText('mc-recovery-first');
      expect(await _syncUntilMarker(client, 'mc-recovery-first'), isNotNull,
          reason:
              'no queue while a client was absent:\n${app.logs.join('\n')}');
      await client.close();

      await _sendPeerChannelText('mc-recovery-second');
      await Future<void>.delayed(const Duration(seconds: 1));
    }

    // Keep one client attached across the grace window, then lose the radio.
    graceClient = _Client(await Socket.connect('127.0.0.1', proxyPort));
    await graceClient.handshake();
    await relay.stop();
    await _waitFor(() => app.deviceReconnecting,
        timeout: const Duration(seconds: 8),
        reason: 'did not enter reconnecting:\n${app.logs.join('\n')}');
    expect(app.proxyStatus, ProxyStatus.running);
    expect(
      (await graceClient.command([cmdGetDeviceTime]))[0],
      respCodeCurrTime,
      reason: 'the client session did not survive the grace window',
    );

    await _waitFor(() => app.deviceWaiting,
        timeout: const Duration(seconds: 30),
        reason: 'did not park:\n${app.logs.join('\n')}');
    await _waitFor(
      () =>
          timers.passiveRequests.isNotEmpty &&
          app.proxyStatus == ProxyStatus.stopped &&
          app.identities.every((identity) => !identity.live),
      reason: 'park did not finish:\n${app.logs.join('\n')}',
    );
    expect(app.proxyStatus, ProxyStatus.stopped);
    expect(await _portOpen(proxyPort), isFalse);

    expect(timers.passiveRequests.first, const Duration(seconds: 30));
    expect(app.recoveryPending, isTrue);
    expect(app.deviceLabel, 'TCP 127.0.0.1:${relay.port}');
    expect(
      app.logs.any((line) =>
          line.contains('waiting for the companion') &&
          line.contains('Device link lost after')),
      isTrue,
      reason: app.logs.join('\n'),
    );
    expect(app.logs.any((line) => line.contains('next attempt in 30s')), isTrue,
        reason: app.logs.join('\n'));
    expect(app.diagnosticsSnapshot().passiveAttempts, 0);
    expect(app.diagnosticsSnapshot().nextPassiveDelay,
        const Duration(seconds: 30));
    expect(foreground.started, isTrue);
    await _waitForTitle(foreground, 'Waiting for companion');
    expect(foreground.stoppedAfterLastStart, isFalse);
    final parked = await _readSession(dir);
    expect(parked['version'], sessionConfigVersion);
    expect(parked['recoveryPending'], isTrue);
    expect(parked['recoveryServeProxy'], isTrue);
    expect(parked['proxyPort'], proxyPort);
    await expectLater(
      graceClient.next(timeout: const Duration(seconds: 2)),
      throwsA(anyOf(isA<StateError>(), isA<TimeoutException>())),
      reason: 'the proxy client was not disconnected at park',
    );

    // Bring the companion back; the parked 30 s timer must restore it.
    await relay.start();
    await _waitFor(() => app.deviceConnected,
        timeout: const Duration(seconds: 40),
        reason: 'passive TCP retry did not restore:\n${app.logs.join('\n')}');
    expect(app.proxyStatus, ProxyStatus.running);
    expect(app.port, proxyPort);
    expect(app.diagnosticsSnapshot().passiveSuccesses, 1);
    expect(app.diagnosticsSnapshot().nextPassiveDelay, isNull);
    expect(app.recoveryPending, isFalse);
    expect(
      app.logs.any((line) => line
          .contains('Companion recovered; proxy listening on port $proxyPort')),
      isTrue,
      reason: app.logs.join('\n'),
    );
    expect(app.identities.every((identity) => identity.live), isTrue);
    await _waitForTitle(foreground, 'Proxy running');
    final restored = await _readSession(dir);
    expect(restored['recoveryPending'], isFalse);
    expect(restored['recoveryServeProxy'], isFalse);

    restoredClient = _Client(await Socket.connect('127.0.0.1', proxyPort));
    await restoredClient.handshake();
    final self = await restoredClient.command([
      cmdAppStart,
      appProtocolVersion,
      0,
      0,
      0,
      0,
      0,
      0,
      ...utf8.encode('RECOVERY-TEST'),
      0,
    ]);
    expect(self[0], respCodeSelfInfo);
    expect(ParsedSelfInfo.parse(self)?.publicKey, identityKey);
    expect(ParsedSelfInfo.parse(self)?.nodeName, 'Recovery Virtual');
    if (_channelPskHex.isNotEmpty) {
      final channel = await restoredClient.command([cmdGetChannel, 0]);
      expect(
          String.fromCharCodes(channel.sublist(2, 34)), contains(_channelName));
    }
    if (_peerHost.isNotEmpty && _channelPskHex.isNotEmpty) {
      expect(
        await _syncUntilMarker(restoredClient, 'mc-recovery-second'),
        isNotNull,
        reason: 'a queued message was lost across park/restore:\n'
            '${app.logs.join('\n')}',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  testWidgets('passive retries follow the capped schedule and throttle logs',
      (tester) async {
    expect(_deviceHost, isNotEmpty, reason: 'Set DEVICE_HOST.');
    final dir = await Directory.systemTemp.createTemp('mc_recovery_schedule_');
    final relay = _Relay(upstreamHost: _deviceHost, upstreamPort: _devicePort);
    final timers = _Timers(divisor: 120);
    final foreground = _RecordingForegroundService();
    final app = _buildApp(dir, timers: timers, foreground: foreground);
    addTearDown(() async {
      await _disposeApp(app);
      timers.cancelAll();
      await relay.stop();
      await dir.delete(recursive: true);
    });

    await app.loadIdentities();
    await _attachViaRelay(app, relay);
    final proxyPort = await _startProxy(app);
    await relay.stop();
    await _waitFor(() => app.deviceWaiting,
        timeout: const Duration(seconds: 30),
        reason: 'did not park:\n${app.logs.join('\n')}');
    await _waitFor(
      () => timers.passiveRequests.length >= 7,
      timeout: const Duration(seconds: 40),
      reason: 'the capped schedule did not advance:\n${app.logs.join('\n')}',
    );

    expect(timers.passiveRequests.take(7).toList(), const [
      Duration(seconds: 30),
      Duration(minutes: 1),
      Duration(minutes: 2),
      Duration(minutes: 5),
      Duration(minutes: 10),
      Duration(minutes: 15),
      Duration(minutes: 15),
    ]);
    // The seventh request is scheduled by the sixth failure; wait for that
    // attempt to run so the repeated 15-minute cap is exercised too.
    await _waitFor(
      () => app.diagnosticsSnapshot().passiveAttempts >= 7,
      timeout: const Duration(seconds: 15),
      reason:
          'the seventh passive attempt did not run:\n${app.logs.join('\n')}',
    );
    expect(timers.passiveRequests.length, greaterThanOrEqualTo(8));
    expect(timers.passiveRequests[7], const Duration(minutes: 15));
    final failures = app.logs
        .where((line) => line.contains('Passive reconnect failed'))
        .length;
    expect(failures, 1,
        reason: 'repeated passive failures are not throttled:\n'
            '${app.logs.join('\n')}');

    await relay.start();
    await app.rearmAfterLinkLoss();
    await _waitFor(() => app.deviceConnected,
        timeout: const Duration(seconds: 10),
        reason: 'foreground nudge did not restore:\n${app.logs.join('\n')}');
    expect(app.proxyStatus, ProxyStatus.running);
    expect(app.port, proxyPort);
    expect(app.diagnosticsSnapshot().passiveSuccesses, 1);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('a proxy stopped by the user stays stopped after recovery',
      (tester) async {
    expect(_deviceHost, isNotEmpty, reason: 'Set DEVICE_HOST.');
    final dir = await Directory.systemTemp.createTemp('mc_recovery_noproxy_');
    final relay = _Relay(upstreamHost: _deviceHost, upstreamPort: _devicePort);
    final timers = _Timers(divisor: 120);
    final foreground = _RecordingForegroundService();
    final app = _buildApp(dir, timers: timers, foreground: foreground);
    addTearDown(() async {
      await _disposeApp(app);
      timers.cancelAll();
      await relay.stop();
      await dir.delete(recursive: true);
    });

    await app.loadIdentities();
    await _attachViaRelay(app, relay);
    await _startProxy(app);
    await app.stopProxy();
    expect(app.proxyStatus, ProxyStatus.stopped);
    await relay.stop();
    await _waitFor(() => app.deviceWaiting,
        timeout: const Duration(seconds: 30),
        reason: 'did not park:\n${app.logs.join('\n')}');
    final parked = await _readSession(dir);
    expect(parked['recoveryPending'], isTrue);
    expect(parked['recoveryServeProxy'], isFalse);

    await relay.start();
    await _waitFor(() => app.deviceConnected,
        timeout: const Duration(seconds: 15),
        reason: 'recovery did not restore the link:\n${app.logs.join('\n')}');
    expect(app.proxyStatus, ProxyStatus.stopped);
    expect(app.identities.every((identity) => identity.live), isTrue);
    expect(
        app.logs.any((line) => line.contains('proxy remains stopped')), isTrue);
    await _waitForTitle(foreground, 'Device linked');
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('a failed proxy restart leaves the recovered link connected',
      (tester) async {
    expect(_deviceHost, isNotEmpty, reason: 'Set DEVICE_HOST.');
    final dir = await Directory.systemTemp.createTemp('mc_recovery_portbusy_');
    final relay = _Relay(upstreamHost: _deviceHost, upstreamPort: _devicePort);
    final timers = _Timers(divisor: 120);
    final foreground = _RecordingForegroundService();
    final app = _buildApp(dir, timers: timers, foreground: foreground);
    addTearDown(() async {
      await _disposeApp(app);
      timers.cancelAll();
      await relay.stop();
      await dir.delete(recursive: true);
    });

    await app.loadIdentities();
    await _attachViaRelay(app, relay);
    final proxyPort = await _startProxy(app);
    await relay.stop();
    await _waitFor(() => app.deviceWaiting,
        timeout: const Duration(seconds: 30),
        reason: 'did not park:\n${app.logs.join('\n')}');
    await _waitFor(
      () =>
          timers.passiveRequests.isNotEmpty &&
          app.proxyStatus == ProxyStatus.stopped,
      reason: 'park did not finish:\n${app.logs.join('\n')}',
    );

    // Occupy the saved proxy port so the automatic restart cannot bind.
    final blocker = await ServerSocket.bind(InternetAddress.anyIPv4, proxyPort);
    addTearDown(() async {
      await blocker.close();
    });
    await relay.start();
    await _waitFor(() => app.deviceConnected,
        timeout: const Duration(seconds: 15),
        reason: 'a failed proxy restart tore down the link:\n'
            '${app.logs.join('\n')}');
    expect(app.proxyStatus, ProxyStatus.stopped);
    expect(
        app.logs.any((line) => line.contains('Failed to start proxy')), isTrue,
        reason: app.logs.join('\n'));
    expect(app.identities.every((identity) => identity.live), isTrue);
    await _waitForTitle(foreground, 'Device linked');
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('a second outage after recovery starts a fresh wait cycle',
      (tester) async {
    expect(_deviceHost, isNotEmpty, reason: 'Set DEVICE_HOST.');
    final dir = await Directory.systemTemp.createTemp('mc_recovery_twice_');
    final relay = _Relay(upstreamHost: _deviceHost, upstreamPort: _devicePort);
    final timers = _Timers(divisor: 120);
    final foreground = _RecordingForegroundService();
    final app = _buildApp(dir, timers: timers, foreground: foreground);
    addTearDown(() async {
      await _disposeApp(app);
      timers.cancelAll();
      await relay.stop();
      await dir.delete(recursive: true);
    });

    await app.loadIdentities();
    await _attachViaRelay(app, relay);
    final proxyPort = await _startProxy(app);

    await relay.stop();
    await _waitFor(() => app.deviceWaiting,
        timeout: const Duration(seconds: 30),
        reason: 'first outage did not park:\n${app.logs.join('\n')}');
    await _waitFor(() =>
        app.diagnosticsSnapshot().passiveSuccesses == 0 &&
        app.proxyStatus == ProxyStatus.stopped &&
        timers.passiveRequests.isNotEmpty);
    await relay.start();
    await _waitFor(
        () =>
            app.deviceConnected &&
            app.diagnosticsSnapshot().passiveSuccesses == 1,
        timeout: const Duration(seconds: 15),
        reason: 'first recovery failed:\n${app.logs.join('\n')}');
    expect(app.proxyStatus, ProxyStatus.running);

    await relay.stop();
    await _waitFor(() => app.deviceWaiting,
        timeout: const Duration(seconds: 30),
        reason: 'second outage did not park:\n${app.logs.join('\n')}');
    await _waitFor(
      () => app.recoveryPending && timers.passiveRequests.length >= 2,
      reason: 'second wait did not arm a fresh retry:\n'
          '${app.logs.join('\n')}',
    );
    expect(timers.passiveRequests.last, const Duration(seconds: 30),
        reason: 'the retry schedule was not reset after recovery');
    await relay.start();
    await _waitFor(
        () =>
            app.deviceConnected &&
            app.diagnosticsSnapshot().passiveSuccesses == 2,
        timeout: const Duration(seconds: 15),
        reason: 'second recovery failed:\n${app.logs.join('\n')}');
    expect(app.proxyStatus, ProxyStatus.running);
    expect(app.port, proxyPort);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('the waiting UI keeps the device label and Cancel ends the wait',
      (tester) async {
    expect(_deviceHost, isNotEmpty, reason: 'Set DEVICE_HOST.');
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dir = await Directory.systemTemp.createTemp('mc_recovery_ui_');
    final relay = _Relay(upstreamHost: _deviceHost, upstreamPort: _devicePort);
    final timers = _Timers(divisor: 120);
    final foreground = _RecordingForegroundService();
    final app = _buildApp(dir, timers: timers, foreground: foreground);
    addTearDown(() async {
      await _disposeApp(app);
      timers.cancelAll();
      await relay.stop();
      await dir.delete(recursive: true);
    });

    await app.loadIdentities();
    await _attachViaRelay(app, relay);
    await _startProxy(app);
    await relay.stop();
    await _waitFor(() => app.deviceWaiting,
        timeout: const Duration(seconds: 30),
        reason: 'did not park:\n${app.logs.join('\n')}');

    await tester.pumpWidget(
      ChangeNotifierProvider<AppViewState>.value(
        value: app,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await _settle(tester);
    expect(
        find.text('Waiting for TCP 127.0.0.1:${relay.port}'), findsOneWidget);
    expect(
      find.text(
        'Proxy stopped. It will restart automatically when the companion '
        'returns.',
      ),
      findsOneWidget,
    );
    final proxySwitch = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Proxy server'));
    expect(proxySwitch.value, isFalse);
    expect(proxySwitch.onChanged, isNull);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);

    // The Connect screen must not cancel a parked recovery when popped.
    await tester.tap(find.text('Device link'));
    await _settle(tester);
    expect(find.byType(ConnectScreen), findsOneWidget);
    expect(
      find.text(
          'Waiting for the companion. The proxy restarts when it returns.'),
      findsOneWidget,
    );
    await tester.pageBack();
    await _settle(tester);
    expect(app.deviceWaiting, isTrue);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await _pumpUntil(tester, () => app.devicePhase == DeviceLinkPhase.idle,
        reason: 'Cancel did not return to idle:\n${app.logs.join('\n')}');
    await _settle(tester);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsNothing);
    expect(app.recoveryPending, isFalse);
    expect((await _readSession(dir))['recoveryPending'], isFalse);
    expect(app.lastSession, isNotNull);
    expect(foreground.stoppedAfterLastStart, isTrue);

    await relay.start();
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(app.devicePhase, DeviceLinkPhase.idle,
        reason: 'a canceled wait resumed on its own');
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('choosing a new target during a wait cancels the parked recovery',
      (tester) async {
    expect(_deviceHost, isNotEmpty, reason: 'Set DEVICE_HOST.');
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dir = await Directory.systemTemp.createTemp('mc_recovery_switch_');
    final relay = _Relay(upstreamHost: _deviceHost, upstreamPort: _devicePort);
    final timers = _Timers(divisor: 120);
    final foreground = _RecordingForegroundService();
    final app = _buildApp(dir, timers: timers, foreground: foreground);
    addTearDown(() async {
      await _disposeApp(app);
      timers.cancelAll();
      await relay.stop();
      await dir.delete(recursive: true);
    });

    await app.loadIdentities();
    await _attachViaRelay(app, relay);
    await _startProxy(app);
    await relay.stop();
    await _waitFor(() => app.deviceWaiting,
        timeout: const Duration(seconds: 30),
        reason: 'did not park:\n${app.logs.join('\n')}');
    // Make the parked target reachable again so a completed wait would restore;
    // the new target must win instead.
    await relay.start();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppViewState>.value(
        value: app,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await _settle(tester);

    await tester.tap(find.text('Device link'));
    await _settle(tester);
    expect(find.byType(ConnectScreen), findsOneWidget);
    expect(find.text('TCP 127.0.0.1:${relay.port}'), findsWidgets,
        reason: 'the waiting status card lost the parked device label');
    final fields =
        tester.widgetList<TextFormField>(find.byType(TextFormField)).toList();
    fields[0].controller!.text = _deviceHost;
    fields[1].controller!.text = '$_devicePort';
    await tester.pump();
    await tester.tap(find.text('Connect over TCP'));
    await _pumpUntil(tester, () => app.deviceConnected,
        reason: 'the new target did not attach:\n${app.logs.join('\n')}');
    await _settle(tester);
    expect(find.byType(ConnectScreen), findsNothing);
    expect(app.deviceLabel, 'TCP $_deviceHost:$_devicePort');
    expect(app.proxyStatus, ProxyStatus.stopped);
    expect(app.recoveryPending, isFalse);
    expect(app.lastSession?.host, _deviceHost);
    expect(app.lastSession?.devicePort, _devicePort);
    expect(timers.passiveRequests, isNotEmpty,
        reason: 'the parked wait never scheduled a passive retry');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(app.deviceConnected, isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('Disconnect during a parked wait ends it and keeps the target',
      (tester) async {
    expect(_deviceHost, isNotEmpty, reason: 'Set DEVICE_HOST.');
    final dir =
        await Directory.systemTemp.createTemp('mc_recovery_disconnect_');
    final relay = _Relay(upstreamHost: _deviceHost, upstreamPort: _devicePort);
    final timers = _Timers(divisor: 120);
    final foreground = _RecordingForegroundService();
    final app = _buildApp(dir, timers: timers, foreground: foreground);
    addTearDown(() async {
      await _disposeApp(app);
      timers.cancelAll();
      await relay.stop();
      await dir.delete(recursive: true);
    });

    await app.loadIdentities();
    await _attachViaRelay(app, relay);
    await _startProxy(app);
    final saved = app.lastSession;
    await relay.stop();
    await _waitFor(() => app.deviceWaiting,
        timeout: const Duration(seconds: 30),
        reason: 'did not park:\n${app.logs.join('\n')}');

    await app.disconnectDevice();
    expect(app.devicePhase, DeviceLinkPhase.idle);
    expect(app.proxyStatus, ProxyStatus.stopped);
    expect(app.recoveryPending, isFalse);
    expect(app.lastSession?.host, saved?.host);
    expect(app.lastSession?.devicePort, saved?.devicePort);
    expect(foreground.stoppedAfterLastStart, isTrue);

    await relay.start();
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(app.devicePhase, DeviceLinkPhase.idle,
        reason: 'a disconnected wait resumed on its own');
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('backup restore cancels a parked recovery against old data',
      (tester) async {
    expect(_deviceHost, isNotEmpty, reason: 'Set DEVICE_HOST.');
    final dir = await Directory.systemTemp.createTemp('mc_recovery_backup_');
    final relay = _Relay(upstreamHost: _deviceHost, upstreamPort: _devicePort);
    final timers = _Timers(divisor: 120);
    final foreground = _RecordingForegroundService();
    final app = _buildApp(dir, timers: timers, foreground: foreground);
    addTearDown(() async {
      await _disposeApp(app);
      timers.cancelAll();
      await relay.stop();
      await dir.delete(recursive: true);
    });

    await app.loadIdentities();
    await _attachViaRelay(app, relay);
    await _startProxy(app);
    await relay.stop();
    await _waitFor(() => app.deviceWaiting,
        timeout: const Duration(seconds: 30),
        reason: 'did not park:\n${app.logs.join('\n')}');

    final backup = await app.createBackup('recovery-passphrase');
    final preview = await app.inspectBackup(backup, 'recovery-passphrase');
    expect(await app.restoreBackup(preview), isTrue,
        reason: app.logs.join('\n'));
    expect(app.devicePhase, DeviceLinkPhase.idle);
    expect(app.recoveryPending, isFalse);
    expect((await _readSession(dir))['recoveryPending'], isFalse);

    await relay.start();
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(app.devicePhase, DeviceLinkPhase.idle,
        reason: 'restore left the old recovery armed');
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('a persisted recovery resumes without Resume on launch',
      (tester) async {
    expect(_deviceHost, isNotEmpty, reason: 'Set DEVICE_HOST.');
    final dir =
        await Directory.systemTemp.createTemp('mc_recovery_persist_ok_');
    final relay = _Relay(upstreamHost: _deviceHost, upstreamPort: _devicePort);
    await relay.start();
    final proxyPort = await _freePort();
    await _writeSession(
      dir,
      SessionConfig(
        kind: DeviceTargetKind.tcp,
        host: InternetAddress.loopbackIPv4.address,
        devicePort: relay.port,
        proxyPort: proxyPort,
        autoResume: false,
        recoveryPending: true,
        recoveryServeProxy: true,
      ),
    );
    final timers = _Timers(divisor: 120);
    final foreground = _RecordingForegroundService();
    final app = _buildApp(dir, timers: timers, foreground: foreground);
    addTearDown(() async {
      await _disposeApp(app);
      timers.cancelAll();
      await relay.stop();
      await dir.delete(recursive: true);
    });

    await app.loadIdentities();
    await _waitFor(() => app.deviceConnected,
        timeout: const Duration(seconds: 20),
        reason: 'persisted recovery did not attach:\n${app.logs.join('\n')}');
    await _waitFor(() => app.proxyStatus == ProxyStatus.running,
        timeout: const Duration(seconds: 10),
        reason: 'persisted recovery did not restart the proxy:\n'
            '${app.logs.join('\n')}');
    expect(app.autoResume, isFalse);
    expect(app.port, proxyPort);
    expect(app.recoveryPending, isFalse);
    final persisted = await _readSession(dir);
    expect(persisted['recoveryPending'], isFalse);
    expect(persisted['recoveryServeProxy'], isFalse);
    await _waitForTitle(foreground, 'Proxy running');
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('a persisted recovery respects a manually stopped proxy',
      (tester) async {
    expect(_deviceHost, isNotEmpty, reason: 'Set DEVICE_HOST.');
    final dir =
        await Directory.systemTemp.createTemp('mc_recovery_persist_noproxy_');
    final relay = _Relay(upstreamHost: _deviceHost, upstreamPort: _devicePort);
    await relay.start();
    await _writeSession(
      dir,
      SessionConfig(
        kind: DeviceTargetKind.tcp,
        host: InternetAddress.loopbackIPv4.address,
        devicePort: relay.port,
        proxyPort: await _freePort(),
        autoResume: false,
        recoveryPending: true,
        recoveryServeProxy: false,
      ),
    );
    final timers = _Timers(divisor: 120);
    final foreground = _RecordingForegroundService();
    final app = _buildApp(dir, timers: timers, foreground: foreground);
    addTearDown(() async {
      await _disposeApp(app);
      timers.cancelAll();
      await relay.stop();
      await dir.delete(recursive: true);
    });

    await app.loadIdentities();
    await _waitFor(() => app.deviceConnected,
        timeout: const Duration(seconds: 20),
        reason: 'persisted recovery did not attach:\n${app.logs.join('\n')}');
    expect(app.proxyStatus, ProxyStatus.stopped);
    await _waitForTitle(foreground, 'Device linked');
    final persisted = await _readSession(dir);
    expect(persisted['recoveryPending'], isFalse);
    expect(persisted['recoveryServeProxy'], isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('a persisted recovery failure parks with the saved proxy intent',
      (tester) async {
    expect(_deviceHost, isNotEmpty, reason: 'Set DEVICE_HOST.');
    final dir =
        await Directory.systemTemp.createTemp('mc_recovery_persist_park_');
    final relay = _Relay(upstreamHost: _deviceHost, upstreamPort: _devicePort);
    await relay.start();
    final relayPort = relay.port;
    await relay.stop();
    await _writeSession(
      dir,
      SessionConfig(
        kind: DeviceTargetKind.tcp,
        host: InternetAddress.loopbackIPv4.address,
        devicePort: relayPort,
        proxyPort: await _freePort(),
        autoResume: false,
        recoveryPending: true,
        recoveryServeProxy: false,
      ),
    );
    final timers = _Timers(divisor: 120);
    final foreground = _RecordingForegroundService();
    final app = _buildApp(dir, timers: timers, foreground: foreground);
    addTearDown(() async {
      await _disposeApp(app);
      timers.cancelAll();
      await relay.stop();
      await dir.delete(recursive: true);
    });

    await app.loadIdentities();
    await _waitFor(() => app.deviceWaiting,
        timeout: const Duration(seconds: 30),
        reason: 'persisted recovery failure did not park:\n'
            '${app.logs.join('\n')}');
    expect(app.recoveryPending, isTrue);
    expect(timers.passiveRequests.first, const Duration(seconds: 30));
    final parked = await _readSession(dir);
    expect(parked['recoveryPending'], isTrue);
    expect(parked['recoveryServeProxy'], isFalse);

    await relay.start();
    await _waitFor(() => app.deviceConnected,
        timeout: const Duration(seconds: 15),
        reason: 'parked recovery did not restore:\n${app.logs.join('\n')}');
    expect(app.proxyStatus, ProxyStatus.stopped);
    expect(
        app.logs.any((line) => line.contains('proxy remains stopped')), isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('a failed cold-start resume returns to idle instead of parking',
      (tester) async {
    final dir = await Directory.systemTemp.createTemp('mc_recovery_cold_');
    final closedPort = await _freePort();
    await _writeSession(
      dir,
      SessionConfig(
        kind: DeviceTargetKind.tcp,
        host: InternetAddress.loopbackIPv4.address,
        devicePort: closedPort,
        proxyPort: await _freePort(),
        autoResume: true,
      ),
    );
    final timers = _Timers(divisor: 120);
    final foreground = _RecordingForegroundService();
    final app = _buildApp(dir, timers: timers, foreground: foreground);
    addTearDown(() async {
      await _disposeApp(app);
      timers.cancelAll();
      await dir.delete(recursive: true);
    });

    await app.loadIdentities();
    expect(app.devicePhase, DeviceLinkPhase.idle,
        reason: 'cold-start resume parked:\n${app.logs.join('\n')}');
    expect(app.recoveryPending, isFalse);
    expect(timers.passiveRequests, isEmpty);
    expect(
        app.logs.any((line) => line.contains('Resuming last device session')),
        isTrue);
    expect(foreground.stoppedAfterLastStart, isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets(
      'Cancel during an initial connect is immediate and drops a late socket',
      (tester) async {
    final dir = await Directory.systemTemp.createTemp('mc_recovery_cancel_');
    final relay = _Relay(upstreamHost: _deviceHost, upstreamPort: _devicePort);
    await relay.start();
    final connector = Completer<Socket>();
    late final TcpDeviceLink rawLink;
    rawLink = TcpDeviceLink(
      host: '127.0.0.1',
      port: relay.port,
      socketConnector: (host, port, timeout) => connector.future,
    );
    final timers = _Timers();
    final foreground = _RecordingForegroundService();
    final app = _buildApp(
      dir,
      timers: timers,
      foreground: foreground,
      tcpLinkFactory: (host, port, onLog) => rawLink,
    );
    addTearDown(() async {
      await _disposeApp(app);
      timers.cancelAll();
      await relay.stop();
      await dir.delete(recursive: true);
    });

    await app.loadIdentities();
    final attempt = app.connectTcp(
      host: '127.0.0.1',
      tcpPort: relay.port,
    );
    await _waitFor(() => app.deviceConnecting,
        timeout: const Duration(seconds: 5),
        reason: 'connect did not start:\n${app.logs.join('\n')}');
    expect(
      foreground.events
          .any((e) => e.startsWith('start|Connecting to companion')),
      isTrue,
      reason: foreground.events.join('\n'),
    );

    final started = DateTime.now();
    await app.cancelDeviceAttempt();
    expect(DateTime.now().difference(started),
        lessThan(const Duration(seconds: 1)),
        reason: 'Cancel waited for the uncancelable TCP connect');

    // Complete the late physical connect; the generation guard must discard it.
    connector.complete(await Socket.connect('127.0.0.1', relay.port));
    await attempt.timeout(const Duration(seconds: 5));
    await _waitFor(() => app.devicePhase == DeviceLinkPhase.idle,
        timeout: const Duration(seconds: 5),
        reason:
            'canceled attach did not settle at idle:\n${app.logs.join('\n')}');
    expect(app.deviceConnected, isFalse);
    expect(app.link, isNull);
    expect(app.proxyStatus, ProxyStatus.stopped);
    expect(app.busy, isFalse);
    expect(foreground.stoppedAfterLastStart, isTrue);
    expect(app.lastSession, isNull,
        reason: 'a canceled attach recorded a session');
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets(
      'the foreground nudge restores a wait without waiting for the timer',
      (tester) async {
    expect(_deviceHost, isNotEmpty, reason: 'Set DEVICE_HOST.');
    final dir = await Directory.systemTemp.createTemp('mc_recovery_nudge_');
    final relay = _Relay(upstreamHost: _deviceHost, upstreamPort: _devicePort);
    final timers = _Timers(divisor: 120, holdPassive: true);
    final foreground = _RecordingForegroundService();
    final app = _buildApp(dir, timers: timers, foreground: foreground);
    addTearDown(() async {
      await _disposeApp(app);
      timers.cancelAll();
      await relay.stop();
      await dir.delete(recursive: true);
    });

    await app.loadIdentities();
    await _attachViaRelay(app, relay);
    final proxyPort = await _startProxy(app);
    await relay.stop();
    await _waitFor(() => app.deviceWaiting,
        timeout: const Duration(seconds: 30),
        reason: 'did not park:\n${app.logs.join('\n')}');
    await relay.start();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(app.deviceWaiting, isTrue,
        reason: 'the held passive timer fired unexpectedly');

    await app.rearmAfterLinkLoss();
    await _waitFor(() => app.deviceConnected,
        timeout: const Duration(seconds: 10),
        reason: 'rearmAfterLinkLoss did not restore:\n${app.logs.join('\n')}');
    expect(app.proxyStatus, ProxyStatus.running);
    expect(app.port, proxyPort);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

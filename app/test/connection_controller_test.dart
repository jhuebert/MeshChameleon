import 'dart:io';

import 'package:device_link/device_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/services/connection_controller.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/identity_manager.dart';
import 'package:meshchameleon/services/network_connection_history.dart';
import 'package:meshchameleon/services/network_connection_store.dart';
import 'package:meshchameleon/services/session_settings.dart';
import 'package:meshchameleon/services/session_store.dart';

class _MemorySessionStore extends SessionStore {
  _MemorySessionStore() : super(file: File('/tmp/unused-session.json'));

  SessionConfig? config;

  @override
  Future<SessionConfig?> load() async => config;

  @override
  Future<void> save(SessionConfig value) async => config = value;
}

class _FakeHost implements ConnectionHost {
  @override
  bool busy = false;

  @override
  bool proxyRunning = false;

  @override
  bool identityCatalogReady = true;

  int notifications = 0;
  int resets = 0;
  int proxyStarts = 0;
  int proxyStops = 0;
  int foregroundStarts = 0;
  int foregroundStops = 0;
  int notes = 0;

  final logs = <String>[];
  SessionConfig? recordedSession;
  (String, int)? recordedNetwork;

  @override
  IdentityManager? get manager => null;

  @override
  Future<IdentityManager> ensureManager() async =>
      throw UnsupportedError('no manager in this test');

  @override
  void notify() => notes++;

  @override
  void log(String message) => logs.add(message);

  @override
  Future<void> stopProxy() async {
    proxyStops++;
    proxyRunning = false;
  }

  @override
  Future<void> startProxy({int? serverPort}) async {
    proxyStarts++;
    proxyRunning = true;
  }

  @override
  Future<void> startForegroundService() async => foregroundStarts++;

  @override
  Future<void> stopForegroundService() async => foregroundStops++;

  @override
  Future<void> updateNotification() async => notifications++;

  @override
  void resetNotificationState() => resets++;

  @override
  Future<void> recordSession(SessionConfig session) async =>
      recordedSession = session;

  @override
  Future<void> recordNetworkConnection(String host, int port) async =>
      recordedNetwork = (host, port);
}

void main() {
  late _FakeHost host;
  late SessionSettings settings;
  late ConnectionController controller;

  setUp(() {
    host = _FakeHost();
    settings = SessionSettings(
      store: _MemorySessionStore(),
      onLog: host.log,
    );
    controller = ConnectionController(
      host: host,
      tcpLinkFactory: (_, __, ___) =>
          throw UnsupportedError('no TCP in this test'),
      capabilities: const DeviceCapabilities(supportsBle: false),
      metrics: LinkMetrics(),
      sessionSettings: settings,
      networkHistory: NetworkConnectionHistory(
        store: NetworkConnectionStore(file: File('/tmp/unused-history.json')),
        onLog: host.log,
        onChanged: host.notify,
      ),
      reconnectDelay: Duration.zero,
    );
  });

  test('rejects an invalid TCP target before creating a link', () async {
    expect(await controller.connectTcp(host: '  ', tcpPort: 0), isFalse);
    expect(host.logs.single, contains('Enter a host'));
    expect(host.busy, isFalse);
  });

  test('disconnecting without a link still stops the foreground service',
      () async {
    await controller.disconnect();

    expect(host.foregroundStops, 1);
    expect(host.resets, 1);
    expect(host.proxyStops, 0);
    expect(host.busy, isFalse);
    expect(host.notes, greaterThanOrEqualTo(2));
  });

  test('power-off suppresses resume and tears down the proxy', () async {
    await settings.setAutoResume(true);
    await settings.record(const SessionConfig(
      kind: DeviceTargetKind.simulated,
    ));
    host.proxyRunning = true;

    await controller.handlePoweredOff();

    expect(settings.intentionallyOff, isTrue);
    expect(host.proxyStops, 1);
    expect(host.foregroundStops, 1);
    expect(host.resets, 1);
    expect(host.logs.join('\n'), contains('automatic reconnect suppressed'));
  });

  test('resume skips when there is no saved session', () async {
    await controller.resumeSession();
    expect(host.logs, isEmpty);
    expect(host.proxyStarts, 0);
  });

  test('resume skips when auto-resume is disabled', () async {
    await settings.record(const SessionConfig(
      kind: DeviceTargetKind.simulated,
    ));

    await controller.resumeSession();

    expect(host.logs, isEmpty);
    expect(host.proxyStarts, 0);
  });

  test('resume skips after an intentional shutdown', () async {
    await settings.setAutoResume(true);
    await settings.record(const SessionConfig(
      kind: DeviceTargetKind.simulated,
    ));
    await settings.markPoweredOff();

    await controller.resumeSession();

    expect(host.logs.single, contains('intentional shutdown'));
    expect(host.proxyStarts, 0);
  });

  test('resume skips while the identity catalog is unavailable', () async {
    host.identityCatalogReady = false;
    await settings.setAutoResume(true);
    await settings.record(const SessionConfig(
      kind: DeviceTargetKind.simulated,
    ));

    await controller.resumeSession();

    expect(host.logs, isEmpty);
    expect(host.proxyStarts, 0);
  });

  test('cancelling with no pending connection is a no-op', () async {
    await controller.cancelPendingConnection();
    expect(host.logs, isEmpty);
  });
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/services/connection_controller.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/device_link_phase.dart';
import 'package:meshchameleon/services/identity_manager.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_runtime.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/network_connection_history.dart';
import 'package:meshchameleon/services/network_connection_store.dart';
import 'package:meshchameleon/services/session_settings.dart';
import 'package:meshchameleon/services/session_store.dart';
import 'package:test_support/test_support.dart';

class _MemorySessionStore extends SessionStore {
  _MemorySessionStore() : super(file: File('/tmp/unused-session.json'));

  SessionConfig? config;

  @override
  Future<SessionConfig?> load() async => config;

  @override
  Future<void> save(SessionConfig value) async => config = value;
}

class _FakeManager extends IdentityManager {
  _FakeManager()
      : super(
          repository: IdentityRepository(
            supportDirectory: Directory('/tmp/meshchameleon-controller'),
            secureStore: IdentityStore(),
          ),
        );

  int starts = 0;
  int stops = 0;
  int reapplies = 0;

  @override
  bool get loaded => true;

  @override
  String? get databaseError => null;

  @override
  List<IdentityRuntime> get runtimes => const [];

  @override
  MeshNode? get activeNode => null;

  @override
  Future<void> startLive({
    required RadioLink base,
    required PhysicalCapabilities physical,
    required RadioParams radioParams,
    Uint8List? devicePublicKey,
  }) async {
    starts++;
  }

  @override
  Future<void> stopLive({bool notify = true}) async => stops++;

  @override
  Future<void> reapplyPhysical({
    required PhysicalCapabilities physical,
    required RadioParams radioParams,
    TuningParams? tuning,
  }) async {
    reapplies++;
  }
}

/// Connects at the link level but fails the post-connect handshake.
class _HandshakeFailLink extends FakeDeviceLink {
  _HandshakeFailLink()
      : super(deviceInfo_: const DeviceInfo(firmwareVerCode: 14));

  bool failHandshake = false;

  @override
  Future<DeviceInfo> deviceInfo() async {
    if (failHandshake) throw StateError('device gone');
    return super.deviceInfo();
  }
}

class _ProbeLink extends FakeDeviceLink {
  _ProbeLink() : super(deviceInfo_: const DeviceInfo(firmwareVerCode: 14));

  void Function()? onConnect;

  @override
  Future<void> connect() async {
    onConnect?.call();
    return super.connect();
  }
}

class _GateConnectLink extends FakeDeviceLink {
  _GateConnectLink()
      : super(deviceInfo_: const DeviceInfo(firmwareVerCode: 14));

  bool gated = false;
  final started = Completer<void>();

  final gate = Completer<void>();

  @override
  Future<void> connect() async {
    if (gated) {
      if (!started.isCompleted) started.complete();
      await gate.future;
    }
    return super.connect();
  }
}

class _FakeHost implements ConnectionHost {
  _FakeHost({this.manager});

  @override
  final IdentityManager? manager;

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
  Future<void> Function(SessionConfig)? onRecordSession;
  (String, int)? recordedNetwork;

  @override
  Future<IdentityManager> ensureManager() async =>
      manager ?? (throw UnsupportedError('no manager in this test'));

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
  Future<void> recordSession(SessionConfig session) async {
    recordedSession = session;
    await onRecordSession?.call(session);
  }

  @override
  Future<void> recordNetworkConnection(String host, int port) async =>
      recordedNetwork = (host, port);
}

void main() {
  late _FakeHost host;
  late SessionSettings settings;
  late ConnectionController controller;

  setUp(() {
    host = _FakeHost(manager: _FakeManager());
    settings = SessionSettings(
      store: _MemorySessionStore(),
      onLog: host.log,
    );
    host.onRecordSession = settings.record;
    controller = ConnectionController(
      host: host,
      tcpLinkFactory: (_, __, ___) =>
          throw UnsupportedError('no TCP in this test'),
      bleLinkFactory: (_, __) => throw UnsupportedError('no BLE in this test'),
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

  ConnectionController build({
    TcpDeviceLinkFactory? tcp,
    BleLinkFactory? ble,
    RecoveryTimerFactory? timer,
    int maxFailures = 3,
    bool supportsBle = false,
  }) =>
      ConnectionController(
        host: host,
        tcpLinkFactory: tcp ??
            (_, __, ___) => throw UnsupportedError('no TCP in this test'),
        bleLinkFactory:
            ble ?? (_, __) => throw UnsupportedError('no BLE in this test'),
        capabilities: DeviceCapabilities(supportsBle: supportsBle),
        metrics: LinkMetrics(),
        sessionSettings: settings,
        networkHistory: NetworkConnectionHistory(
          store: NetworkConnectionStore(file: File('/tmp/unused-history.json')),
          onLog: host.log,
          onChanged: host.notify,
        ),
        reconnectDelay: Duration.zero,
        maxReconnectFailures: maxFailures,
        timerFactory: timer ?? Timer.new,
      );

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('the foreground service starts before the physical connect attempt',
      () async {
    final link = _ProbeLink();
    var serviceWasRunning = false;
    link.onConnect = () => serviceWasRunning = host.foregroundStarts > 0;
    final c = build(tcp: (_, __, ___) => link);

    expect(await c.connectTcp(host: 'radio.example', tcpPort: 5000), isTrue);
    expect(serviceWasRunning, isTrue);
  });

  test('a failed initial attach stops the service again', () async {
    final link = FakeDeviceLink()
      ..deviceInfoError =
          const DeviceCommandError.malformed(message: 'device unavailable');
    await settings.record(const SessionConfig(
      kind: DeviceTargetKind.tcp,
      host: 'radio.example',
      devicePort: 5000,
    ));
    final c = build(tcp: (_, __, ___) => link);
    final stopsBefore = host.foregroundStops;

    expect(await c.connectTcp(host: 'radio.example', tcpPort: 5000), isFalse);

    expect(c.devicePhase, DeviceLinkPhase.idle);
    expect(host.foregroundStops, greaterThan(stopsBefore));
  });

  test('a short drop reconnects without stopping the proxy or runtimes',
      () async {
    final link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    final c = build(tcp: (_, __, ___) => link);
    expect(await c.connectTcp(host: 'radio.example', tcpPort: 5000), isTrue);
    await host.startProxy();
    final stopsBefore = (host.manager as _FakeManager).stops;

    link.simulateDrop();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(c.devicePhase, DeviceLinkPhase.connected);
    expect(host.proxyStops, 0);
    expect((host.manager as _FakeManager).stops, stopsBefore);
  });

  test('a surrendered physical session parks, then cancel returns to idle',
      () async {
    final link = _HandshakeFailLink();
    final c = build(tcp: (_, __, ___) => link);
    expect(await c.connectTcp(host: 'radio.example', tcpPort: 5000), isTrue);
    await host.startProxy();
    final stopsBefore = (host.manager as _FakeManager).stops;
    final foregroundStopsBefore = host.foregroundStops;

    link.failHandshake = true;
    link.simulateDrop();
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(c.devicePhase, DeviceLinkPhase.waiting);
    expect(host.proxyStops, 1);
    expect(host.foregroundStops, foregroundStopsBefore);
    expect((host.manager as _FakeManager).stops, greaterThan(stopsBefore));
    expect(settings.recoveryPending, isTrue);
    expect(settings.recoveryServeProxy, isTrue);
    expect(c.deviceLabel, 'TCP radio.example:5000');

    final resetsBefore = host.resets;
    await c.cancelDeviceAttempt();

    expect(c.devicePhase, DeviceLinkPhase.idle);
    expect(settings.recoveryPending, isFalse);
    expect(host.foregroundStops, greaterThan(0));
    expect(host.resets, greaterThan(resetsBefore));
  });

  test('TCP passive retries follow the capped schedule and then restore',
      () async {
    final scheduler = FakeScheduler();
    final link = _HandshakeFailLink();
    final c = build(
      tcp: (_, __, ___) => link,
      timer: scheduler.create,
    );
    expect(await c.connectTcp(host: 'radio.example', tcpPort: 5000), isTrue);
    await host.startProxy();

    link.failHandshake = true;
    link.simulateDrop();
    for (var i = 0; i < 20 && c.devicePhase != DeviceLinkPhase.waiting; i++) {
      scheduler.elapse(Duration.zero);
      await settle();
    }
    expect(c.devicePhase, DeviceLinkPhase.waiting);
    expect(host.proxyStops, 1);

    link.connectFailures = 100;
    scheduler.elapse(const Duration(seconds: 30));
    await settle();
    expect(c.passiveAttempts, 1);
    expect(c.nextPassiveDelay, const Duration(minutes: 1));

    scheduler.elapse(const Duration(minutes: 1));
    await settle();
    expect(c.passiveAttempts, 2);
    expect(c.nextPassiveDelay, const Duration(minutes: 2));

    link
      ..connectFailures = 0
      ..failHandshake = false;
    scheduler.elapse(const Duration(minutes: 2));
    await settle();

    expect(c.devicePhase, DeviceLinkPhase.connected,
        reason: host.logs.join('\n'));
    expect(host.proxyStarts, 2);
    expect(settings.recoveryPending, isFalse);
  });

  test('cancel during a parked TCP wait removes the retry timer', () async {
    final scheduler = FakeScheduler();
    final link = _HandshakeFailLink();
    final c = build(
      tcp: (_, __, ___) => link,
      timer: scheduler.create,
    );
    expect(await c.connectTcp(host: 'radio.example', tcpPort: 5000), isTrue);
    await host.startProxy();
    link.failHandshake = true;
    link.simulateDrop();
    for (var i = 0; i < 20 && c.devicePhase != DeviceLinkPhase.waiting; i++) {
      scheduler.elapse(Duration.zero);
      await settle();
    }
    expect(c.devicePhase, DeviceLinkPhase.waiting);

    await c.cancelDeviceAttempt();
    expect(c.devicePhase, DeviceLinkPhase.idle);
    final attempts = c.passiveAttempts;

    scheduler.elapse(const Duration(minutes: 20));
    await settle();

    expect(c.passiveAttempts, attempts);
    expect(c.devicePhase, DeviceLinkPhase.idle);
  });

  test('a notification follows the reconnect grace period and recovery',
      () async {
    final link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    final c = build(tcp: (_, __, ___) => link);
    expect(await c.connectTcp(host: 'radio.example', tcpPort: 5000), isTrue);
    await host.startProxy();
    final before = host.notifications;

    link.simulateDrop();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(c.devicePhase, DeviceLinkPhase.connected);
    // One update for entering `reconnecting`, one for returning to `connected`.
    expect(host.notifications, greaterThanOrEqualTo(before + 2));
  });

  test('a parked BLE recovery watches a link created after a cold start',
      () async {
    final link = _HandshakeFailLink()..failHandshake = true;
    await settings.record(const SessionConfig(
      kind: DeviceTargetKind.ble,
      bleRemoteId: 'AA:BB:CC:DD:EE:03',
      bleName: 'MeshCore-nc3',
    ));
    await settings.markRecoveryPending(serveProxy: true);
    final c = build(
      ble: (_, __) => link,
      supportsBle: true,
    );

    await c.recoverPendingSession();
    await settle();

    expect(c.devicePhase, DeviceLinkPhase.waiting);
    expect(link.passiveRequested, isTrue);

    link.failHandshake = false;
    await link.simulatePassiveConnect();
    await settle();

    expect(c.devicePhase, DeviceLinkPhase.connected,
        reason: host.logs.join('\n'));
    expect(host.proxyStarts, 1);
    expect(settings.recoveryPending, isFalse);
    await c.cancelDeviceAttempt();
  });

  test('a cold-start recovery keeps its persisted intent until it settles',
      () async {
    final link = _GateConnectLink()..gated = true;
    await settings.record(const SessionConfig(
      kind: DeviceTargetKind.tcp,
      host: 'radio.example',
      devicePort: 5000,
    ));
    await settings.markRecoveryPending(serveProxy: false);
    final c = build(tcp: (_, __, ___) => link);

    final recovering = c.recoverPendingSession();
    await link.started.future;
    // The attach starts by tearing the session down; that must not clear the
    // persisted intent while the physical attempt is still in flight.
    expect(settings.recoveryPending, isTrue);

    link.gate.complete();
    await recovering;
    await settle();

    expect(c.devicePhase, DeviceLinkPhase.connected,
        reason: host.logs.join('\n'));
    expect(settings.recoveryPending, isFalse);
    await c.cancelDeviceAttempt();
  });

  test('a saved BLE recovery ends cleanly when this build has no BLE',
      () async {
    await settings.record(const SessionConfig(
      kind: DeviceTargetKind.ble,
      bleRemoteId: 'AA:BB:CC:DD:EE:04',
    ));
    await settings.markRecoveryPending(serveProxy: true);
    final c = build();

    await c.recoverPendingSession();
    await settle();

    expect(c.devicePhase, DeviceLinkPhase.idle);
    expect(settings.recoveryPending, isFalse);
    expect(host.proxyStarts, 0);
  });

  test('a failed cold-start resume returns to idle instead of parking',
      () async {
    final link = _HandshakeFailLink()..failHandshake = true;
    await settings.setAutoResume(true);
    await settings.record(const SessionConfig(
      kind: DeviceTargetKind.tcp,
      host: 'radio.example',
      devicePort: 5000,
      autoResume: true,
    ));
    final c = build(tcp: (_, __, ___) => link);

    await c.resumeSession();

    expect(c.devicePhase, DeviceLinkPhase.idle);
    expect(settings.recoveryPending, isFalse);
    expect(host.proxyStarts, 0);
  });

  test('a persisted recovery failure parks and preserves proxy intent',
      () async {
    final link = _HandshakeFailLink()..failHandshake = true;
    await settings.record(const SessionConfig(
      kind: DeviceTargetKind.tcp,
      host: 'radio.example',
      devicePort: 5000,
      autoResume: false,
    ));
    await settings.markRecoveryPending(serveProxy: true);
    final c = build(tcp: (_, __, ___) => link);

    await c.recoverPendingSession();
    await settle();

    expect(c.devicePhase, DeviceLinkPhase.waiting);
    expect(settings.recoveryPending, isTrue);
    expect(settings.recoveryServeProxy, isTrue);
    expect(host.proxyStarts, 0);

    await c.cancelDeviceAttempt();
  });
}

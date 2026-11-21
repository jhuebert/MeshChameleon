import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/network_connection_store.dart';
import 'package:meshchameleon/services/phone_battery_service.dart';
import 'package:meshchameleon/services/phone_location_service.dart';
import 'package:meshchameleon/services/session_store.dart';
import 'package:test_support/test_support.dart';

const _capabilities = DeviceCapabilities(
  supportsBle: false,
);

class _GateStore extends NetworkConnectionStore {
  _GateStore(File file) : super(file: file);

  final Completer<void> gate = Completer<void>();

  @override
  Future<void> save(List<SavedNetworkConnection> connections) async {
    await gate.future;
    await super.save(connections);
  }
}

class _FailingSessionStore extends SessionStore {
  @override
  Future<void> save(SessionConfig config) async {
    throw StateError('session write failed');
  }
}

class _SlowDisconnectLink extends FakeDeviceLink {
  _SlowDisconnectLink({super.deviceInfo_});

  final Completer<void> gate = Completer<void>();

  @override
  Future<void> disconnect() async {
    await gate.future;
    return super.disconnect();
  }
}

class _GateInfoLink extends FakeDeviceLink {
  _GateInfoLink({super.deviceInfo_});

  final Completer<void> infoGate = Completer<void>();
  final Completer<void> infoStarted = Completer<void>();

  @override
  Future<DeviceInfo> deviceInfo() async {
    if (!infoStarted.isCompleted) infoStarted.complete();
    await infoGate.future;
    return super.deviceInfo();
  }
}

/// Reconnects at the link level but fails the post-connect handshake.
class _HandshakeFailLink extends FakeDeviceLink {
  _HandshakeFailLink({super.deviceInfo_});

  bool failHandshake = false;

  @override
  Future<DeviceInfo> deviceInfo() async {
    if (failHandshake) throw StateError('device gone');
    return super.deviceInfo();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late IdentityRepository repository;
  late SessionStore sessionStore;
  late NetworkConnectionStore networkConnectionStore;
  late AppState app;

  AppState buildApp({
    SessionStore? session,
    NetworkConnectionStore? connections,
    TcpDeviceLinkFactory? tcpLinkFactory,
    BleLinkFactory? bleLinkFactory,
    DeviceCapabilities capabilities = _capabilities,
    RecoveryTimerFactory? recoveryTimerFactory,
    PhoneBatteryService? phoneBattery,
    PhoneLocationService? phoneLocation,
  }) =>
      AppState(
        repository: repository,
        sessionStore: session ?? sessionStore,
        networkConnectionStore: connections ?? networkConnectionStore,
        tcpLinkFactory: tcpLinkFactory,
        bleLinkFactory: bleLinkFactory,
        recoveryTimerFactory: recoveryTimerFactory,
        capabilities: capabilities,
        phoneBattery: phoneBattery,
        phoneLocation: phoneLocation,
        reconnectDelay: const Duration(milliseconds: 10),
      );

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('mesh_app_state_');
    repository = IdentityRepository(
      supportDirectory: dir,
      secureStore: IdentityStore(),
    );
    sessionStore = SessionStore(file: File('${dir.path}/session.json'));
    networkConnectionStore = NetworkConnectionStore(
        file: File('${dir.path}/network_connections.json'));
    app = buildApp();
    await app.loadIdentities();
  });

  tearDown(() async {
    await app.disconnectDevice();
    await app.manager?.dispose();
    await dir.delete(recursive: true);
  });

  Future<Uint8List> handshake(FramedClient client) async {
    final w = BufferWriter()
      ..writeByte(cmdAppStart)
      ..writeBytes(List.filled(7, 0))
      ..writeString('test')
      ..writeByte(0);
    client.send(w.toBytes());
    final info = await client.frames.next();
    expect(info[0], respCodeSelfInfo);
    return info.sublist(4, 36);
  }

  test('phone telemetry wiring exposes status and writes GPS settings',
      () async {
    var settingsOpened = 0;
    final battery = PhoneBatteryService(readLevel: () async => 42);
    final location = PhoneLocationService(
      checkPermission: () async => LocationPermission.denied,
      requestPermission: () async => LocationPermission.denied,
      openSettings: () async {
        settingsOpened++;
        return true;
      },
    );
    app = buildApp(phoneBattery: battery, phoneLocation: location);
    await app.loadIdentities();

    // No active node yet: controls report failure instead of throwing.
    expect(await app.setPhoneGpsEnabled(true), isFalse);
    expect(await app.setPhoneGpsInterval(60), isFalse);

    await app.refreshPhoneTelemetry();
    expect(app.phoneBatteryPercent, 42);
    expect(app.phoneGpsRequested, isFalse);
    expect(app.phoneLocationPermissionLabel, 'Denied');
    expect(app.phoneGpsIntervalSeconds, isNull);
    expect(app.phoneGpsLastFixAge, isNull);
    expect(app.phoneGpsLastError, isNull);
    expect(app.foregroundIncludesLocation, isFalse);
    expect(await app.requestPhoneLocationPermission(), isFalse);
    expect(await app.openPhoneLocationSettings(), isTrue);
    expect(settingsOpened, 1);

    await app.connectSimulated();
    addTearDown(app.disconnectDevice);
    expect(app.node, isNotNull, reason: app.logs.join('\n'));

    expect(await app.setPhoneGpsEnabled(true), isTrue);
    expect(app.node!.gpsEnabled, isTrue);
    expect(await app.setPhoneGpsInterval(30), isTrue);
    expect(app.node!.getCustomVars()['gps_interval'], '30');
    expect(app.phoneGpsIntervalSeconds, 30);
  });

  test('GPS editing is identity-scoped and radio health is shared', () async {
    final location = PhoneLocationService(
      checkPermission: () async => LocationPermission.denied,
    );
    app = buildApp(phoneLocation: location);
    await app.loadIdentities();
    final firstId = app.activeIdentity!.id;
    final second = await app.createIdentity(name: 'Second');
    expect(second, isNotNull);
    final link = FakeDeviceLink();
    expect(await app.connectSimulated(simulatedLink: link), isTrue);
    await app.node!.battery.refresh();
    final health = app.radioHealth;
    expect(health, isNotNull);
    final reads = link.batteryReads;

    expect(await app.activateIdentity(second!.id), isTrue);
    expect(await app.setPhoneGpsEnabled(true), isTrue);
    expect(await app.setPhoneGpsInterval(60), isTrue);
    expect(await app.activateIdentity(firstId), isTrue);
    expect(app.activeGpsScope!.requested, isFalse);
    expect(app.activeGpsScope!.configuredIntervalSeconds, 900);
    expect(app.phoneGpsRequested, isTrue);
    expect(app.phoneGpsIntervalSeconds, 60);
    expect(app.radioHealth!.sampledAt, health!.sampledAt);
    for (var i = 0; i < 3; i++) {
      app.diagnosticsSnapshot();
      app.radioHealth;
    }
    expect(link.batteryReads, reads);
    await app.disconnectDevice();
    expect(app.radioHealth, isNull);
    expect(app.activeGpsScope, isNull);
  });

  test('cancelling an idle app is a no-op', () async {
    await app.cancelDeviceAttempt();
    expect(app.devicePhase, DeviceLinkPhase.idle);
    expect(app.deviceConnected, isFalse);
  });

  test('the default BLE factory reports a failed connect in this test build',
      () async {
    final bleApp = buildApp(
      capabilities: const DeviceCapabilities(supportsBle: true),
    );
    addTearDown(bleApp.disconnectDevice);
    await bleApp.loadIdentities();

    expect(
      await bleApp.connectBle(BluetoothDevice.fromId('AA:BB:CC:DD:EE:03')),
      isFalse,
    );
    expect(bleApp.devicePhase, DeviceLinkPhase.idle);
  });

  test('fresh install auto-creates and activates one identity', () async {
    expect(app.identityDatabaseError, isNull);
    expect(app.identities, hasLength(1));
    final summary = app.identities.single;
    expect(summary.name, 'MeshChameleon');
    expect(summary.active, isTrue);
    expect(summary.live, isFalse);
    expect(app.activeIdentityId, summary.id);
    expect(app.node, isNull);
  });

  test('attach starts every identity and the proxy serves the active one',
      () async {
    final second = await app.createIdentity(name: 'Second');
    expect(second, isNotNull);
    expect(app.activeIdentityId, isNot(second!.id));

    final link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    await app.connectSimulated(simulatedLink: link);
    addTearDown(app.disconnectDevice);

    expect(app.deviceConnected, isTrue, reason: app.logs.join('\n'));
    expect(app.manager!.runtimes, hasLength(2));
    expect(app.manager!.runtimes.every((runtime) => runtime.live), isTrue);
    expect(app.node, isNotNull);
    expect(app.identities.every((summary) => summary.live), isTrue);

    await app.startProxy(serverPort: 0);
    expect(app.proxyStatus, ProxyStatus.running);
    expect(app.server, isNotNull);

    await app.stopProxy();
    expect(app.proxyStatus, ProxyStatus.stopped);
    expect(app.manager!.runtimes.every((runtime) => runtime.live), isTrue,
        reason: 'stopping the proxy must not stop live identities');
  });

  test('rapid proxy start and stop transitions leave no listener behind',
      () async {
    await app.connectSimulated(
      simulatedLink: FakeDeviceLink(
        deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
      ),
    );
    addTearDown(app.disconnectDevice);

    Future<bool> portOpen(int port) async {
      try {
        final socket = await Socket.connect(
          '127.0.0.1',
          port,
          timeout: const Duration(milliseconds: 300),
        );
        await socket.close();
        return true;
      } catch (_) {
        return false;
      }
    }

    final start = app.startProxy(serverPort: 0);
    final stop = app.stopProxy();
    await Future.wait([start, stop]);

    expect(app.proxyStatus, ProxyStatus.stopped);
    expect(app.server, isNull);
    expect(app.port, greaterThan(0));
    expect(await portOpen(app.port), isFalse,
        reason: 'a queued stop must close the just-started listener');

    final stopFirst = app.stopProxy();
    final startAgain = app.startProxy(serverPort: 0);
    await Future.wait([stopFirst, startAgain]);

    expect(app.proxyStatus, ProxyStatus.running);
    expect(app.server, isNotNull);
    expect(await portOpen(app.port), isTrue,
        reason: 'a queued start must leave the new listener running');
    await app.stopProxy();
  });

  test('diagnostics snapshot reflects proxy and physical traffic', () async {
    final link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    await app.connectSimulated(simulatedLink: link);
    addTearDown(app.disconnectDevice);
    await app.startProxy(serverPort: 0);

    final client = FramedClient(await Socket.connect('127.0.0.1', app.port));
    addTearDown(client.close);
    await handshake(client);

    await app.node!.advertise();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final snapshot = app.diagnosticsSnapshot();
    expect(snapshot.proxyRunning, isTrue);
    expect(snapshot.deviceConnected, isTrue);
    expect(snapshot.deviceInfo?.firmwareVerCode, 14);
    expect(snapshot.companion.clientConnections, 1);
    expect(snapshot.companion.commandsReceived, greaterThanOrEqualTo(1));
    expect(snapshot.link.rawTxPackets, greaterThanOrEqualTo(1));
    expect(snapshot.link.rawTxBytes, greaterThan(0));
    expect(snapshot.identities.single.packets?.sent, greaterThanOrEqualTo(1));
  });

  test('activation switches the client to the new SELF_INFO', () async {
    final second = await app.createIdentity(name: 'Second');
    final link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    await app.connectSimulated(simulatedLink: link);
    addTearDown(app.disconnectDevice);
    await app.startProxy(serverPort: 0);

    final firstClient =
        FramedClient(await Socket.connect('127.0.0.1', app.port));
    addTearDown(firstClient.close);
    final firstKey = await handshake(firstClient);
    expect(firstKey, app.identity!.publicKey);

    expect(await app.activateIdentity(second!.id), isTrue);
    expect(app.server!.hasClient, isFalse);

    final secondClient =
        FramedClient(await Socket.connect('127.0.0.1', app.port));
    addTearDown(secondClient.close);
    final secondKey = await handshake(secondClient);
    expect(secondKey, app.manager!.activeIdentity!.publicKey);
    expect(secondKey, isNot(firstKey));
  });

  test('disable stops a non-active runtime and enable restarts it', () async {
    final first = app.identities.single.id;
    final second = await app.createIdentity(name: 'Second');
    final secondId = second!.id;
    final link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    await app.connectSimulated(simulatedLink: link);
    addTearDown(app.disconnectDevice);

    expect(app.manager!.runtimes, hasLength(2));
    expect(await app.setIdentityEnabled(secondId, false), isTrue);
    expect(app.manager!.runtimes, hasLength(1));
    expect(
      app.identities.firstWhere((summary) => summary.id == secondId).enabled,
      isFalse,
    );
    expect(await app.setIdentityEnabled(first, false), isFalse,
        reason: 'the active identity must stay enabled');
    expect(await app.setIdentityEnabled(secondId, true), isTrue);
    expect(app.manager!.runtimes, hasLength(2));
    expect(
      app.identities.firstWhere((summary) => summary.id == secondId).live,
      isTrue,
    );
  });

  test('create leaves the active identity unchanged and delete is constrained',
      () async {
    final first = app.identities.single.id;
    final second = await app.createIdentity(name: 'Second');

    expect(app.activeIdentityId, first);
    expect(app.identities, hasLength(2));
    expect(await app.deleteIdentity(first), isFalse,
        reason: 'the active identity cannot be deleted');
    expect(await app.deleteIdentity(second!.id), isTrue);
    expect(app.identities, hasLength(1));
  });

  test('clear local data keeps key and name and disconnects the client',
      () async {
    final link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    await app.connectSimulated(simulatedLink: link);
    addTearDown(app.disconnectDevice);
    await app.startProxy(serverPort: 0);
    final node = app.node!;
    await node.setAdvertName('Keep Me');
    await node.addUpdateContact(Contact(
      publicKey: (await LocalIdentity.generate()).publicKey,
      name: 'Peer',
    ));
    final client = FramedClient(await Socket.connect('127.0.0.1', app.port));
    addTearDown(client.close);
    await handshake(client);
    final keyBefore = Uint8List.fromList(node.identity.publicKey);

    expect(await app.clearLocalData(app.activeIdentityId!), isTrue);

    expect(app.server!.hasClient, isFalse);
    expect(app.node!.identity.publicKey, keyBefore);
    expect(app.node!.prefs.nodeName, 'Keep Me');
    expect(app.node!.contacts, isEmpty);
  });

  test('cancelling during startup does not leave a connected ghost session',
      () async {
    final gated = _GateInfoLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    final cancelApp = buildApp(
      tcpLinkFactory: (host, port, onLog) => gated,
    );
    await cancelApp.loadIdentities();
    addTearDown(cancelApp.disconnectDevice);

    final connect = cancelApp.connectTcp(host: 'slow.example', tcpPort: 5000);
    await gated.infoStarted.future.timeout(const Duration(seconds: 5));
    await cancelApp.cancelPendingConnection();
    gated.infoGate.complete();

    expect(await connect, isFalse, reason: cancelApp.logs.join('\n'));
    expect(cancelApp.deviceConnected, isFalse);
    expect(cancelApp.link, isNull);
    expect(cancelApp.lastSession, isNull);
    expect(cancelApp.savedNetworkConnections, isEmpty);
  });

  test('a connect queued behind a slow disconnect keeps the new session',
      () async {
    final slow = _SlowDisconnectLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    final replacement = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    final queuedApp = buildApp(
      tcpLinkFactory: (host, port, onLog) => replacement,
    );
    await queuedApp.loadIdentities();
    addTearDown(queuedApp.disconnectDevice);
    await queuedApp.connectSimulated(simulatedLink: slow);
    expect(queuedApp.deviceConnected, isTrue);

    final disconnect = queuedApp.disconnectDevice();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(queuedApp.busy, isTrue);
    final connect = queuedApp.connectTcp(
      host: 'replacement.example',
      tcpPort: 5000,
    );
    slow.gate.complete();

    await disconnect;
    expect(await connect, isTrue, reason: queuedApp.logs.join('\n'));
    expect(queuedApp.deviceConnected, isTrue);
    expect(queuedApp.link, isNotNull);
    expect(queuedApp.link!.currentState, LinkState.connected);
    expect(queuedApp.lastSession!.host, 'replacement.example');
    expect(replacement.calls, contains('connect'));
    await queuedApp.disconnectDevice();
  });

  test('disconnect stops every runtime but keeps the catalog', () async {
    await app.createIdentity(name: 'Second');
    await app.connectSimulated();
    expect(app.manager!.runtimes, hasLength(2));
    await app.disconnectDevice();

    expect(app.deviceConnected, isFalse);
    expect(app.manager!.runtimes, isEmpty);
    expect(app.identities, hasLength(2));
    expect(app.identities.every((summary) => !summary.live), isTrue);
  });

  test('successful TCP attach records and persists the normalized target',
      () async {
    final fake = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    (String, int)? requested;
    final tcpApp = buildApp(
      tcpLinkFactory: (host, port, onLog) {
        requested = (host, port);
        return fake;
      },
    );
    await tcpApp.loadIdentities();
    addTearDown(tcpApp.disconnectDevice);

    expect(
      await tcpApp.connectTcp(host: ' 192.168.1.55 ', tcpPort: 5000),
      isTrue,
      reason: tcpApp.logs.join('\n'),
    );

    expect(requested, ('192.168.1.55', 5000));
    final saved = tcpApp.savedNetworkConnections.single;
    expect(saved.host, '192.168.1.55');
    expect(saved.port, 5000);
    expect(saved.lastConnectedAt, greaterThan(0));
    final loaded = await NetworkConnectionStore(
      file: File('${dir.path}/network_connections.json'),
    ).load();
    expect(loaded.single, saved);
  });

  test('a failed TCP attach records nothing', () async {
    final fake = FakeDeviceLink()
      ..deviceInfoError =
          const DeviceCommandError.malformed(message: 'device unavailable');
    final tcpApp = buildApp(
      tcpLinkFactory: (host, port, onLog) => fake,
    );
    await tcpApp.loadIdentities();
    addTearDown(tcpApp.disconnectDevice);

    expect(
      await tcpApp.connectTcp(host: '192.168.1.55', tcpPort: 5000),
      isFalse,
    );

    expect(tcpApp.savedNetworkConnections, isEmpty);
    expect(await networkConnectionStore.load(), isEmpty);
  });

  test('invalid TCP targets are rejected before creating a link', () async {
    var created = 0;
    final tcpApp = buildApp(
      tcpLinkFactory: (host, port, onLog) {
        created++;
        return FakeDeviceLink();
      },
    );
    await tcpApp.loadIdentities();
    addTearDown(tcpApp.disconnectDevice);

    expect(await tcpApp.connectTcp(host: '   ', tcpPort: 5000), isFalse);
    expect(await tcpApp.connectTcp(host: 'host', tcpPort: 0), isFalse);
    expect(await tcpApp.connectTcp(host: 'host', tcpPort: 65536), isFalse);

    expect(created, 0);
    expect(tcpApp.savedNetworkConnections, isEmpty);
  });

  test('history loads before auto-resume and keeps every saved target',
      () async {
    final resumeSessionStore =
        SessionStore(file: File('${dir.path}/resume_session.json'));
    await resumeSessionStore.save(const SessionConfig(
      kind: DeviceTargetKind.tcp,
      host: 'resume.example',
      devicePort: 5000,
      proxyPort: 0,
      autoResume: true,
    ));
    final historyStore = NetworkConnectionStore(
      file: File('${dir.path}/resume_connections.json'),
    );
    await historyStore.save([
      const SavedNetworkConnection(
        host: 'older.example',
        port: 5000,
        lastConnectedAt: 100,
      ),
      const SavedNetworkConnection(
        host: 'resume.example',
        port: 5000,
        lastConnectedAt: 200,
      ),
    ]);
    final fake = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    final resumed = buildApp(
      session: resumeSessionStore,
      connections: historyStore,
      tcpLinkFactory: (host, port, onLog) => fake,
    );
    addTearDown(resumed.disconnectDevice);

    await resumed.loadIdentities();

    expect(resumed.deviceConnected, isTrue, reason: resumed.logs.join('\n'));
    expect(resumed.savedNetworkConnections, hasLength(2));
    expect(resumed.savedNetworkConnections.first.host, 'resume.example');
    expect(resumed.savedNetworkConnections.last.host, 'older.example');
    final persisted = await historyStore.load();
    expect(persisted, hasLength(2));
  });

  test('remove and restore update both memory and disk', () async {
    const first = SavedNetworkConnection(
      host: 'first.example',
      port: 5000,
      lastConnectedAt: 300,
    );
    const second = SavedNetworkConnection(
      host: 'second.example',
      port: 6000,
      lastConnectedAt: 200,
    );
    await networkConnectionStore.save([first, second]);
    final historyApp = buildApp();
    await historyApp.loadIdentities();
    addTearDown(historyApp.disconnectDevice);
    expect(historyApp.savedNetworkConnections, [first, second]);

    expect(await historyApp.removeSavedNetworkConnection(first), isTrue);
    expect(historyApp.savedNetworkConnections, [second]);
    expect(await networkConnectionStore.load(), [second]);

    expect(await historyApp.restoreSavedNetworkConnection(first), isTrue);
    expect(historyApp.savedNetworkConnections, [first, second]);
    final restored = await networkConnectionStore.load();
    expect(restored, [first, second]);
    expect(restored.first.lastConnectedAt, 300);
  });

  test('overlapping remove and connect do not lose history', () async {
    final file = File('${dir.path}/race_connections.json');
    const first = SavedNetworkConnection(
      host: 'first.example',
      port: 5000,
      lastConnectedAt: 100,
    );
    const second = SavedNetworkConnection(
      host: 'second.example',
      port: 6000,
      lastConnectedAt: 200,
    );
    await NetworkConnectionStore(file: file).save([first, second]);
    final store = _GateStore(file);
    final fake = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    final raceApp = buildApp(
      connections: store,
      tcpLinkFactory: (host, port, onLog) => fake,
    );
    await raceApp.loadIdentities();
    addTearDown(raceApp.disconnectDevice);

    final remove = raceApp.removeSavedNetworkConnection(first);
    final connect =
        raceApp.connectTcp(host: 'connected.example', tcpPort: 7000);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    store.gate.complete();

    expect(await remove, isTrue);
    expect(await connect, isTrue, reason: raceApp.logs.join('\n'));
    final history = raceApp.savedNetworkConnections;
    expect(history, hasLength(2));
    expect(
      history.map((connection) => connection.key),
      containsAll([second.key, 'connected.example:7000']),
    );
  });

  test('a session write failure keeps a successful TCP connection', () async {
    final fake = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    final tcpApp = buildApp(
      session: _FailingSessionStore(),
      tcpLinkFactory: (host, port, onLog) => fake,
    );
    await tcpApp.loadIdentities();
    addTearDown(tcpApp.disconnectDevice);

    expect(
      await tcpApp.connectTcp(host: 'host.example', tcpPort: 5000),
      isTrue,
      reason: tcpApp.logs.join('\n'),
    );

    expect(tcpApp.deviceConnected, isTrue);
    expect(
      tcpApp.logs.join('\n'),
      contains('Could not save the last session'),
    );
  });

  test('a history write failure keeps a successful TCP connection', () async {
    final fake = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    final tcpApp = buildApp(
      connections: NetworkConnectionStore(file: File(dir.path)),
      tcpLinkFactory: (host, port, onLog) => fake,
    );
    await tcpApp.loadIdentities();
    addTearDown(tcpApp.disconnectDevice);

    expect(
        await tcpApp.connectTcp(host: 'host.example', tcpPort: 5000), isTrue);

    expect(tcpApp.deviceConnected, isTrue);
    expect(tcpApp.savedNetworkConnections, hasLength(1));
    expect(
      tcpApp.logs.join('\n'),
      contains('Could not save network connection history'),
    );
  });

  test('BLE and simulated connect report whether they succeeded', () async {
    expect(
      await app.connectBle(BluetoothDevice.fromId('AA:BB:CC:DD:EE:FF')),
      isFalse,
    );
    expect(await app.connectSimulated(), isTrue, reason: app.logs.join('\n'));
    addTearDown(app.disconnectDevice);
  });

  test('physical shutdown stops runtimes and suppresses auto-resume', () async {
    await app.setAutoResume(true);
    final link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    await app.connectSimulated(simulatedLink: link);
    addTearDown(app.disconnectDevice);
    expect(app.intentionallyOff, isFalse);

    await app.node!.shutdown();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(app.intentionallyOff, isTrue);
    expect(app.deviceConnected, isFalse);
    expect(app.manager!.runtimes, isEmpty);
    final saved = await sessionStore.load();
    expect(saved!.intentionallyOff, isTrue);

    final resumed = buildApp();
    addTearDown(resumed.disconnectDevice);
    await resumed.loadIdentities();
    expect(resumed.deviceConnected, isFalse);
    expect(resumed.logs.join('\n'), contains('intentional shutdown'));
  });

  test('every drop is watched, including one after a reconnect', () async {
    final link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    await app.connectSimulated(simulatedLink: link);
    addTearDown(app.disconnectDevice);
    int connects() => link.calls.where((c) => c == 'connect').length;
    expect(connects(), 1);

    link.simulateDrop();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(connects(), 2);
    expect(app.deviceConnected, isTrue);
    expect(app.logs.join('\n'), contains('Device link reconnected'));

    // Regression: a fired reconnect timer used to stay non-null, so this drop
    // was ignored and the session kept reporting a live link forever.
    link.simulateDrop();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(connects(), 3);
    expect(app.deviceConnected, isTrue);
  });

  test('disconnecting cancels a scheduled reconnect', () async {
    final link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    await app.connectSimulated(simulatedLink: link);
    addTearDown(app.disconnectDevice);

    link.simulateDrop();
    await app.disconnectDevice();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(app.deviceConnected, isFalse);
    expect(app.logs.join('\n'), isNot(contains('Reconnecting device ...')));
  });

  test('failed reconnects stop the proxy and end the session', () async {
    final link = _HandshakeFailLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    await app.connectSimulated(simulatedLink: link);
    addTearDown(app.disconnectDevice);
    await app.startProxy(serverPort: 0);
    expect(app.proxyStatus, ProxyStatus.running);

    link.failHandshake = true;
    link.simulateDrop();
    await Future<void>.delayed(Duration.zero);
    expect(app.deviceReconnecting, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(app.deviceConnected, isFalse);
    expect(app.deviceReconnecting, isFalse);
    expect(app.proxyStatus, ProxyStatus.stopped);
    expect(app.logs.join('\n'), contains('stopping the session'));
  });

  test('a dropped BLE session parks and recovers through passive connect',
      () async {
    final link = _HandshakeFailLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    final bleApp = buildApp(
      capabilities: const DeviceCapabilities(supportsBle: true),
      bleLinkFactory: (_, __) => link,
    );
    addTearDown(bleApp.disconnectDevice);
    await bleApp.loadIdentities();

    expect(
      await bleApp.connectBle(
        BluetoothDevice.fromId('AA:BB:CC:DD:EE:01'),
        displayName: 'MeshCore-nc3',
      ),
      isTrue,
      reason: bleApp.logs.join('\n'),
    );
    await bleApp.startProxy(serverPort: 0);
    expect(bleApp.proxyStatus, ProxyStatus.running);

    link.failHandshake = true;
    link.simulateDrop();
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(bleApp.devicePhase, DeviceLinkPhase.waiting);
    expect(bleApp.proxyStatus, ProxyStatus.stopped);
    expect(bleApp.manager!.runtimes, isEmpty);
    expect(link.passiveRequested, isTrue);
    expect(bleApp.lastSession!.recoveryPending, isTrue);
    expect(bleApp.lastSession!.recoveryServeProxy, isTrue);
    expect(bleApp.deviceLabel, 'BLE MeshCore-nc3');

    // The companion is seen again; the OS-level request reconnects.
    link.failHandshake = false;
    await link.simulatePassiveConnect();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(bleApp.devicePhase, DeviceLinkPhase.connected);
    expect(bleApp.proxyStatus, ProxyStatus.running);
    expect(bleApp.lastSession!.recoveryPending, isFalse);
    expect(bleApp.logs.join('\n'), contains('Companion recovered'));
  });

  test('recovery does not restart a proxy stopped before the drop', () async {
    final link = _HandshakeFailLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    final bleApp = buildApp(
      capabilities: const DeviceCapabilities(supportsBle: true),
      bleLinkFactory: (_, __) => link,
    );
    addTearDown(bleApp.disconnectDevice);
    await bleApp.loadIdentities();
    await bleApp.connectBle(
      BluetoothDevice.fromId('AA:BB:CC:DD:EE:02'),
      displayName: 'MeshCore-nc1',
    );
    await bleApp.startProxy(serverPort: 0);
    await bleApp.stopProxy();

    link.failHandshake = true;
    link.simulateDrop();
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(bleApp.devicePhase, DeviceLinkPhase.waiting);
    expect(bleApp.lastSession!.recoveryServeProxy, isFalse);

    link.failHandshake = false;
    await link.simulatePassiveConnect();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(bleApp.devicePhase, DeviceLinkPhase.connected);
    expect(bleApp.proxyStatus, ProxyStatus.stopped);
    expect(bleApp.logs.join('\n'), contains('proxy remains stopped'));
  });

  test('a persisted recovery reconnects at startup even with resume off',
      () async {
    final store = SessionStore(file: File('${dir.path}/recovery.json'));
    await store.save(const SessionConfig(
      kind: DeviceTargetKind.tcp,
      host: 'resume.example',
      devicePort: 5000,
      proxyPort: 0,
      autoResume: false,
      recoveryPending: true,
      recoveryServeProxy: true,
    ));
    final fake = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    final recovered = buildApp(
      session: store,
      tcpLinkFactory: (host, port, onLog) => fake,
    );
    addTearDown(recovered.disconnectDevice);

    await recovered.loadIdentities();

    expect(recovered.deviceConnected, isTrue,
        reason: recovered.logs.join('\n'));
    expect(recovered.proxyStatus, ProxyStatus.running);
    final saved = await store.load();
    expect(saved!.recoveryPending, isFalse);
    expect(saved.recoveryServeProxy, isFalse);
  });

  test('a failed persisted recovery parks instead of returning to idle',
      () async {
    final store = SessionStore(file: File('${dir.path}/recovery_fail.json'));
    await store.save(const SessionConfig(
      kind: DeviceTargetKind.tcp,
      host: 'resume.example',
      devicePort: 5000,
      proxyPort: 0,
      autoResume: false,
      recoveryPending: true,
      recoveryServeProxy: true,
    ));
    final fake = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    )..deviceInfoError =
        const DeviceCommandError.malformed(message: 'device unavailable');
    final failed = buildApp(
      session: store,
      tcpLinkFactory: (host, port, onLog) => fake,
    );
    addTearDown(failed.disconnectDevice);

    await failed.loadIdentities();

    expect(failed.devicePhase, DeviceLinkPhase.waiting,
        reason: failed.logs.join('\n'));
    expect(failed.proxyStatus, ProxyStatus.stopped);
    expect(failed.deviceLabel, 'TCP resume.example:5000');
    final saved = await store.load();
    expect(saved!.recoveryPending, isTrue);
    expect(saved.recoveryServeProxy, isTrue);
    await failed.cancelDeviceAttempt();
  });

  test('clearing data without a device updates persisted summaries', () async {
    final id = app.identities.single.id;
    await repository.saveState(
      id,
      NodeState(
        prefs: NodePrefs(nodeName: 'Offline Name'),
        contacts: [
          Contact(
            publicKey: (await LocalIdentity.generate()).publicKey,
            name: 'Peer',
          ),
        ],
      ),
    );
    await app.manager!.refreshSummaries();
    expect(app.identities.single.contactCount, 1);

    expect(await app.clearLocalData(id), isTrue);

    expect(app.identities.single.name, 'Offline Name');
    expect(app.identities.single.contactCount, 0);
  });

  test('backup and restore round-trip through app state', () async {
    final id = app.activeIdentityId!;
    final bytes = await app.createBackup('backup passphrase');
    final preview = await app.inspectBackup(bytes, 'backup passphrase');
    expect(preview.identityCount, 1);

    final state = (await repository.loadState(id))!;
    state.prefs.nodeName = 'Changed';
    await repository.saveState(id, state);

    expect(await app.restoreBackup(preview), isTrue);
    final restored = (await repository.loadState(id))!;
    expect(restored.prefs.nodeName, 'MeshChameleon');
    expect(app.activeIdentityId, id);
  });

  test('log bursts coalesce into one listener notification', () async {
    var notifications = 0;
    void listener() => notifications++;
    app.addListener(listener);
    addTearDown(() => app.removeListener(listener));

    app.log('first line');
    app.log('second line');
    expect(notifications, 1);

    await Future<void>.delayed(Duration.zero);
    expect(notifications, 1);
    expect(
      app.logs.where((line) => line.contains('line')),
      hasLength(2),
    );
  });
}

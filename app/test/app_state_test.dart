import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/network_connection_store.dart';
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
    DeviceCapabilities capabilities = _capabilities,
  }) =>
      AppState(
        repository: repository,
        sessionStore: session ?? sessionStore,
        networkConnectionStore: connections ?? networkConnectionStore,
        tcpLinkFactory: tcpLinkFactory,
        capabilities: capabilities,
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
      ..writeByte(appProtocolVersion)
      ..writeBytes(List.filled(6, 0))
      ..writeString('test')
      ..writeByte(0);
    client.send(w.toBytes());
    final info = await client.frames.next();
    expect(info[0], respCodeSelfInfo);
    return info.sublist(4, 36);
  }

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

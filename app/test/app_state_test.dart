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

const _capabilities = DeviceCapabilities(
  supportsBle: false,
  supportsSimulatedCompanion: true,
);

class _FramedClient {
  _FramedClient(this.socket) {
    socket.listen((data) {
      for (final frame in _codec.ingest(data)) {
        _controller.add(frame);
      }
    });
  }

  final Socket socket;
  final SerialFrameCodec _codec = SerialFrameCodec.bidirectional();
  final StreamController<Uint8List> _controller =
      StreamController<Uint8List>.broadcast();
  late final StreamQueue<Uint8List> frames = StreamQueue(_controller.stream);

  void send(List<int> payload) {
    socket.add(_codec.encodeFrame(payload, prefix: frameInboundPrefix));
  }

  Future<void> close() async {
    await _controller.close();
    await socket.close();
  }
}

class StreamQueue<T> {
  StreamQueue(Stream<T> stream) {
    stream.listen(_add);
  }
  final List<T> _buffer = [];
  final List<Completer<T>> _waiters = [];

  Future<T> next() {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    final c = Completer<T>();
    _waiters.add(c);
    return c.future;
  }

  Future<T?> nextWithin(Duration timeout) async {
    if (_buffer.isNotEmpty) return _buffer.removeAt(0);
    final c = Completer<T>();
    _waiters.add(c);
    try {
      return await c.future.timeout(timeout);
    } on TimeoutException {
      _waiters.remove(c);
      return null;
    }
  }

  void _add(T value) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(value);
    } else {
      _buffer.add(value);
    }
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

  Future<Uint8List> handshake(_FramedClient client) async {
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

  test('activation switches the client to the new SELF_INFO', () async {
    final second = await app.createIdentity(name: 'Second');
    final link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    await app.connectSimulated(simulatedLink: link);
    addTearDown(app.disconnectDevice);
    await app.startProxy(serverPort: 0);

    final firstClient =
        _FramedClient(await Socket.connect('127.0.0.1', app.port));
    addTearDown(firstClient.close);
    final firstKey = await handshake(firstClient);
    expect(firstKey, app.identity!.publicKey);

    expect(await app.activateIdentity(second!.id), isTrue);
    expect(app.server!.hasClient, isFalse);

    final secondClient =
        _FramedClient(await Socket.connect('127.0.0.1', app.port));
    addTearDown(secondClient.close);
    final secondKey = await handshake(secondClient);
    expect(secondKey, app.manager!.activeIdentity!.publicKey);
    expect(secondKey, isNot(firstKey));
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
    final client = _FramedClient(await Socket.connect('127.0.0.1', app.port));
    addTearDown(client.close);
    await handshake(client);
    final keyBefore = Uint8List.fromList(node.identity.publicKey);

    expect(await app.clearLocalData(app.activeIdentityId!), isTrue);

    expect(app.server!.hasClient, isFalse);
    expect(app.node!.identity.publicKey, keyBefore);
    expect(app.node!.prefs.nodeName, 'Keep Me');
    expect(app.node!.contacts, isEmpty);
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

    final releaseShaped = buildApp(
      capabilities: const DeviceCapabilities(
        supportsBle: false,
        supportsSimulatedCompanion: false,
      ),
    );
    await releaseShaped.loadIdentities();
    addTearDown(releaseShaped.disconnectDevice);
    expect(await releaseShaped.connectSimulated(), isFalse);
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
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_store.dart';
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
  late AppState app;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('mesh_app_state_');
    repository = IdentityRepository(
      supportDirectory: dir,
      secureStore: IdentityStore(),
    );
    sessionStore = SessionStore(file: File('${dir.path}/session.json'));
    app = AppState(
      repository: repository,
      sessionStore: sessionStore,
      capabilities: _capabilities,
      reconnectDelay: const Duration(milliseconds: 10),
    );
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

    final resumed = AppState(
      repository: repository,
      sessionStore: sessionStore,
      capabilities: _capabilities,
    );
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

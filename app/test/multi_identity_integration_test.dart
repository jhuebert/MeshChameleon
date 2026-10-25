import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_runtime.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/network_connection_store.dart';
import 'package:meshchameleon/services/session_store.dart';

const _capabilities = DeviceCapabilities(
  supportsBle: false,
  supportsSimulatedCompanion: true,
);

class _Sink implements CompanionPushSink {
  final List<int> confirmed = [];

  @override
  void pushSendConfirmed(int ackCrc) => confirmed.add(ackCrc);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

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
  late final _Queue<Uint8List> frames = _Queue(_controller.stream);

  void send(List<int> payload) {
    socket.add(_codec.encodeFrame(payload, prefix: frameInboundPrefix));
  }

  Future<void> close() async {
    await _controller.close();
    try {
      await socket.close();
    } catch (_) {}
  }
}

class _Queue<T> {
  _Queue(Stream<T> stream) {
    stream.listen((value) {
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete(value);
      } else {
        _buffer.add(value);
      }
    });
  }

  final List<T> _buffer = [];
  final List<Completer<T>> _waiters = [];

  Future<T> next() {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    final completer = Completer<T>();
    _waiters.add(completer);
    return completer.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late IdentityRepository repository;
  late AppState app;
  late FakeRadioBus bus;
  late FakeDeviceLink appLink;
  late FakeDeviceLink peerLink;
  late MeshNode peer;
  late IdentityRuntime runtimeA;
  late IdentityRuntime runtimeB;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('mesh_multi_integration_');
    repository = IdentityRepository(
      supportDirectory: dir,
      secureStore: IdentityStore(),
    );
    app = AppState(
      repository: repository,
      sessionStore: SessionStore(file: File('${dir.path}/session.json')),
      networkConnectionStore: NetworkConnectionStore(
        file: File('${dir.path}/network_connections.json'),
      ),
      capabilities: _capabilities,
    );
    await app.loadIdentities();
    await app.createIdentity(name: 'B');

    bus = FakeRadioBus();
    peerLink = FakeDeviceLink(bus: bus);
    await peerLink.connect();
    peer = MeshNode(identity: await LocalIdentity.generate(), link: peerLink);
    await peer.load();
    peer.start();

    appLink = FakeDeviceLink(
      bus: bus,
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    await app.connectSimulated(simulatedLink: appLink);
    runtimeA = app.manager!.runtimes
        .firstWhere((runtime) => runtime.record.name == 'MeshChameleon');
    runtimeB = app.manager!.runtimes
        .firstWhere((runtime) => runtime.record.name == 'B');

    await peer.addUpdateContact(Contact(
      publicKey: runtimeB.identity!.publicKey,
      name: 'B',
      outPathLen: 0,
      outPath: Uint8List(0),
    ));
    await runtimeB.node!.addUpdateContact(Contact(
      publicKey: peer.identity.publicKey,
      name: 'Peer',
      outPathLen: 0,
      outPath: Uint8List(0),
    ));
    await runtimeA.node!.addUpdateContact(Contact(
      publicKey: peer.identity.publicKey,
      name: 'Peer',
      outPathLen: 0,
      outPath: Uint8List(0),
    ));
    await runtimeA.node!.addUpdateContact(Contact(
      publicKey: runtimeB.identity!.publicKey,
      name: 'B',
      outPathLen: 0,
      outPath: Uint8List(0),
    ));
    await runtimeB.node!.addUpdateContact(Contact(
      publicKey: runtimeA.identity!.publicKey,
      name: 'MeshChameleon',
      outPathLen: 0,
      outPath: Uint8List(0),
    ));
  });

  tearDown(() async {
    await peer.retire();
    await app.disconnectDevice();
    await app.manager?.dispose();
    await peerLink.disconnect();
    await dir.delete(recursive: true);
  });

  Future<_FramedClient> connectClient() async {
    final client = _FramedClient(await Socket.connect('127.0.0.1', app.port));
    client.send([cmdDeviceQuery, 3]);
    expect((await client.frames.next())[0], respCodeDeviceInfo);
    final w = BufferWriter()
      ..writeByte(cmdAppStart)
      ..writeByte(3)
      ..writeBytes(List.filled(6, 0))
      ..writeString('test')
      ..writeByte(0);
    client.send(w.toBytes());
    final info = await client.frames.next();
    expect(info[0], respCodeSelfInfo);
    return client;
  }

  test('inactive identity receives, queues, switches, and syncs to the client',
      () async {
    await app.startProxy(serverPort: 0);
    var client = await connectClient();
    expect(app.server!.hasClient, isTrue);

    final sent = await peer.sendTextMessage(
      runtimeB.identity!.publicKey,
      'for B only',
    );
    expect(sent.success, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(runtimeB.node!.queuedDirectCount, 1);
    expect(runtimeA.node!.queuedDirectCount, 0);

    expect(await app.activateIdentity(runtimeB.record.id), isTrue);
    expect(app.server!.hasClient, isFalse);
    await client.close();

    client = await connectClient();
    addTearDown(client.close);
    expect(app.server!.hasClient, isTrue);
    expect(app.manager!.activeIdentity!.publicKey,
        runtimeB.identity!.publicKey);

    client.send([cmdSyncNextMessage]);
    final message = await client.frames.next();
    expect(message[0], respCodeContactMsgRecvV3);
    expect(String.fromCharCodes(message).contains('for B only'), isTrue);
    expect(runtimeB.node!.queuedDirectCount, 0);
    expect(runtimeA.node!.queuedDirectCount, 0);
  });

  test('local DM, group text, advert, and attached-key guard work end to end',
      () async {
    expect(await app.activateIdentity(runtimeB.record.id), isTrue);
    await app.startProxy(serverPort: 0);
    final client = await connectClient();
    addTearDown(client.close);

    await peer.setAdvertName('Peer Sender');
    final secret = Uint8List.fromList(List.generate(16, (i) => i + 1));
    await runtimeA.node!.setChannel(1, 'Shared', secret);
    await runtimeB.node!.setChannel(1, 'Shared', secret);
    await peer.setChannel(1, 'Shared', secret);

    final groupBefore = peerLink.transmitted
        .where((raw) => Packet.readFrom(raw)?.payloadType == payloadTypeGrpTxt)
        .length;
    expect(await peer.sendChannelMessage(1, 'group hello'), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final groupAfter = peerLink.transmitted
        .where((raw) => Packet.readFrom(raw)?.payloadType == payloadTypeGrpTxt)
        .length;
    expect(groupAfter - groupBefore, 1,
        reason: 'the single RF group packet reaches both local identities');
    expect(runtimeA.node!.queuedChannelCount, 1);
    expect(runtimeB.node!.queuedChannelCount, 1);

    // B is active; A is live and inactive.
    final sink = _Sink();
    runtimeB.node!.setPushSink(sink);
    final localSent = await runtimeB.node!.sendTextMessage(
      runtimeA.identity!.publicKey,
      'local delivery',
    );
    await Future<void>.delayed(const Duration(milliseconds: 350));

    expect(localSent.success, isTrue);
    expect(runtimeA.node!.queuedDirectCount, 1);
    expect(sink.confirmed, contains(localSent.expectedAck),
        reason: 'the mirrored ACK confirms the active sender');

    final dRecord = await app.createIdentity(name: 'D');
    final runtimeD = app.manager!.runtimes
        .firstWhere((runtime) => runtime.record.id == dRecord!.id);
    expect(runtimeD.node, isNotNull);
    expect(
      runtimeD.node!.contacts.any(
        (contact) => bytesToHex(contact.publicKey) ==
            bytesToHex(runtimeB.identity!.publicKey),
      ),
      isFalse,
    );

    await runtimeB.node!.advertise();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(
      runtimeD.node!.contacts.any(
        (contact) => bytesToHex(contact.publicKey) ==
            bytesToHex(runtimeB.identity!.publicKey),
      ),
      isTrue,
      reason: 'a local advert teaches other identities the sender',
    );

    await runtimeB.node!.addUpdateContact(Contact(
      publicKey: Uint8List(32),
      name: 'Attached radio identity',
      outPathLen: 0,
      outPath: Uint8List(0),
    ));
    final txBefore = appLink.transmitted.length;
    await expectLater(
      runtimeB.node!.sendTextMessage(Uint8List(32), 'unreachable'),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeIllegalArg)),
    );
    expect(appLink.transmitted.length, txBefore);
  });
}

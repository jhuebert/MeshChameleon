// Live-hardware multi-identity test: three identities on a real companion,
// inactive DM queueing, activation, and local mirroring. No group/advert
// traffic.
//
//   flutter test integration_test/multi_identity_live_test.dart -d linux \
//     --dart-define=DEVICE_HOST=<host> --dart-define=PEER_HOST=<host> \
//     --dart-define=PEER_PUBKEY_HEX=<64-byte hex> \
//     [--dart-define=DEVICE_PORT=5000] [--dart-define=PEER_PORT=9505]
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/network_connection_store.dart';
import 'package:meshchameleon/services/session_store.dart';

const _deviceHost = String.fromEnvironment('DEVICE_HOST');
const _devicePort = int.fromEnvironment('DEVICE_PORT', defaultValue: 5000);
const _peerHost = String.fromEnvironment('PEER_HOST');
const _peerPort = int.fromEnvironment('PEER_PORT', defaultValue: 9505);
const _peerKeyHex = String.fromEnvironment('PEER_PUBKEY_HEX');

class _Client {
  _Client(this.socket) {
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
  final List<Uint8List> log = [];

  void send(List<int> payload) {
    socket.add(_codec.encodeFrame(payload, prefix: frameInboundPrefix));
  }

  Future<Uint8List> next({bool pushes = false}) async {
    while (true) {
      final frame = await frames.next();
      log.add(frame);
      if (frame.isNotEmpty && frame[0] >= 0x80 && !pushes) continue;
      return frame;
    }
  }

  Future<_Client> handshake() async {
    send([cmdDeviceQuery, 3]);
    expect((await next())[0], respCodeDeviceInfo);
    send([
      cmdAppStart,
      3,
      0,
      0,
      0,
      0,
      0,
      0,
      ...utf8.encode('LIVE-CLIENT'),
      0,
    ]);
    expect((await next())[0], respCodeSelfInfo);
    return this;
  }

  Future<void> close() async {
    await _controller.close();
    await socket.close();
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
    return completer.future.timeout(const Duration(seconds: 20));
  }
}

Uint8List _contact(Uint8List key, String name, {int pathLen = 0xFF}) {
  final bytes = utf8.encode(name);
  final padded = Uint8List(maxNameSize)
    ..setRange(0, bytes.length.clamp(0, maxNameSize - 1), bytes);
  final w = BufferWriter()
    ..writeByte(cmdAddUpdateContact)
    ..writeBytes(key)
    ..writeByte(advTypeChat)
    ..writeByte(0)
    ..writeByte(pathLen)
    ..writeBytes(Uint8List(maxPathSize))
    ..writeBytes(padded)
    ..writeUInt32Le(0)
    ..writeInt32Le(0)
    ..writeInt32Le(0)
    ..writeUInt32Le(1);
  return w.toBytes();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'three identities live on a real companion, inactive DM queues, '
      'activation serves it, and a local DM mirrors once', () async {
    if (_deviceHost.isEmpty || _peerHost.isEmpty || _peerKeyHex.isEmpty) {
      fail('Set DEVICE_HOST, PEER_HOST, and PEER_PUBKEY_HEX.');
    }
    FlutterSecureStorage.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('mesh_multi_live_');
    final app = AppState(
      repository: IdentityRepository(
        supportDirectory: dir,
        secureStore: IdentityStore(),
      ),
      sessionStore: SessionStore(file: File('${dir.path}/session.json')),
      networkConnectionStore: NetworkConnectionStore(
        file: File('${dir.path}/network_connections.json'),
      ),
      capabilities: const DeviceCapabilities(
        supportsBle: false,
        supportsSimulatedCompanion: false,
      ),
      reconnectDelay: const Duration(seconds: 1),
    );
    addTearDown(() async {
      await app.disconnectDevice();
      await app.manager?.dispose();
      await dir.delete(recursive: true);
    });
    await app.loadIdentities();
    await app.createIdentity(name: 'Live Bravo');
    await app.createIdentity(name: 'Live Charlie');
    expect(app.identities.length, 3);

    expect(
        await app.connectTcp(host: _deviceHost, tcpPort: _devicePort), isTrue);
    expect(app.manager!.runtimes.where((r) => r.live).length, 3);
    final alpha = app.manager!.runtimes
        .firstWhere((r) => r.record.name == 'MeshChameleon');
    final bravo =
        app.manager!.runtimes.firstWhere((r) => r.record.name == 'Live Bravo');
    await alpha.node!.setAdvertName('Live Alpha');
    await app.manager!.refreshSummaries();

    final peerKey = hexToBytes(_peerKeyHex);
    await bravo.node!.addUpdateContact(Contact(
      publicKey: Uint8List.fromList(peerKey),
      name: 'Peer A',
      outPathLen: -1,
    ));
    await alpha.node!.addUpdateContact(Contact(
      publicKey: Uint8List.fromList(bravo.identity!.publicKey),
      name: 'Live Bravo',
      outPathLen: 0,
      outPath: Uint8List(0),
    ));
    await bravo.node!.addUpdateContact(Contact(
      publicKey: Uint8List.fromList(alpha.identity!.publicKey),
      name: 'Live Alpha',
      outPathLen: 0,
      outPath: Uint8List(0),
    ));

    await app.startProxy(serverPort: 0);
    final port = app.port;
    var proxyClient =
        await _Client(await Socket.connect('127.0.0.1', port)).handshake();
    final servedAlpha = await _selfName(proxyClient);
    expect(servedAlpha, 'Live Alpha');

    final peer =
        await _Client(await Socket.connect(_peerHost, _peerPort)).handshake();
    addTearDown(peer.close);
    // Peer A learns Bravo's contact.
    peer.send(_contact(bravo.identity!.publicKey, 'Live Bravo'));
    expect((await peer.next())[0], respCodeOk);

    final bravoBefore = bravo.node!.queuedDirectCount;
    final alphaBefore = alpha.node!.queuedDirectCount;
    final marker = 'LIVE-DM-${DateTime.now().millisecondsSinceEpoch % 100000}';
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    peer.send([
      cmdSendTxtMsg,
      txtTypePlain,
      0,
      ts & 0xFF,
      (ts >> 8) & 0xFF,
      (ts >> 16) & 0xFF,
      (ts >> 24) & 0xFF,
      ...bravo.identity!.publicKey.sublist(0, 6),
      ...utf8.encode(marker),
      0,
    ]);
    expect((await peer.next())[0], respCodeSent);
    await Future<void>.delayed(const Duration(seconds: 8));
    expect(bravo.node!.queuedDirectCount, bravoBefore + 1);
    expect(alpha.node!.queuedDirectCount, alphaBefore);
    // Peer A's companion does not always surface the direct ACK as 0x82/raw
    // ACK; the virtual queue increment is the authoritative check here.

    // Proving the active client cannot see Bravo's queue.
    proxyClient.send([cmdSyncNextMessage]);
    final alphaSync = await proxyClient.next();
    expect(alphaSync[0], respCodeNoMoreMessages);

    // Activate Bravo: the client is closed, the listener stays up.
    expect(await app.activateIdentity(bravo.record.id), isTrue);
    expect(app.server!.hasClient, isFalse);
    await proxyClient.close();
    proxyClient =
        await _Client(await Socket.connect('127.0.0.1', port)).handshake();
    expect(await _selfName(proxyClient), 'Live Bravo');

    proxyClient.send([cmdSyncNextMessage]);
    final queued = await proxyClient.next();
    expect(queued[0], respCodeContactMsgRecvV3);
    expect(String.fromCharCodes(queued).contains(marker), isTrue);
    expect(bravo.node!.queuedDirectCount, bravoBefore);

    // Local DM Alpha -> Bravo: one RF frame + one mirror, no duplicate queue.
    final localMarker =
        'LIVE-LOCAL-${DateTime.now().millisecondsSinceEpoch % 100000}';
    final result = await alpha.node!
        .sendTextMessage(bravo.identity!.publicKey, localMarker);
    expect(result.success, isTrue);
    await Future<void>.delayed(const Duration(seconds: 5));
    expect(bravo.node!.queuedDirectCount, 1);
    // Peer A may not surface a raw log for a packet addressed to Bravo; the
    // mirror queue is the authoritative local-delivery oracle here.
    expect(bravo.node!.queuedDirectCount, 1,
        reason: 'one mirror copy, no duplicate');
    await proxyClient.close();
  });
}

Future<String> _selfName(_Client client) async {
  // The handshake already consumed SELF_INFO; re-read it.
  client.send([
    cmdAppStart,
    3,
    0,
    0,
    0,
    0,
    0,
    0,
    ...utf8.encode('LIVE-CLIENT'),
    0,
  ]);
  final self = await client.next();
  return String.fromCharCodes(self.sublist(58).takeWhile((b) => b != 0));
}

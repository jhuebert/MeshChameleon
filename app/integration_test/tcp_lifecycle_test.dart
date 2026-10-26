// Live app-level TCP lifecycle test: repeated attach/detach plus a reboot with
// a client attached.
//
// This reboots the radio.
//   flutter test integration_test/tcp_lifecycle_test.dart -d linux \
//     --dart-define=DEVICE_HOST=<host> [--dart-define=DEVICE_PORT=5000]
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/network_connection_store.dart';
import 'package:meshchameleon/services/session_store.dart';

const _deviceHost = String.fromEnvironment('DEVICE_HOST');
const _devicePort = int.fromEnvironment('DEVICE_PORT', defaultValue: 5000);

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

  void send(List<int> payload) {
    socket.add(_codec.encodeFrame(payload, prefix: frameInboundPrefix));
  }

  Future<Uint8List> next({bool pushes = false}) async {
    while (true) {
      final frame = await frames.next();
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
      ...utf8.encode('TCP-LIFECYCLE'),
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
    return completer.future.timeout(const Duration(seconds: 25));
  }
}

Future<bool> portOpen(int port) async {
  try {
    final socket = await Socket.connect('127.0.0.1', port,
        timeout: const Duration(milliseconds: 300));
    await socket.close();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('direct attach/detach five times and reboot with client attached',
      (tester) async {
    if (_deviceHost.isEmpty) {
      fail('Set DEVICE_HOST to the companion TCP host.');
    }
    FlutterSecureStorage.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('mesh_direct_');
    final app = AppState(
      repository: IdentityRepository(
        supportDirectory: dir,
        secureStore: IdentityStore(),
      ),
      sessionStore: SessionStore(file: File('${dir.path}/session.json')),
      networkConnectionStore:
          NetworkConnectionStore(file: File('${dir.path}/history.json')),
      capabilities: const DeviceCapabilities(
        supportsBle: false,
        supportsSimulatedCompanion: false,
      ),
      reconnectDelay: const Duration(milliseconds: 500),
    );
    addTearDown(() async {
      await app.disconnectDevice();
      await app.manager?.dispose();
      await dir.delete(recursive: true);
    });
    await app.loadIdentities();

    // Five direct attach/detach cycles, no proxy leaks.
    for (var i = 1; i <= 5; i++) {
      expect(
          await app.connectTcp(host: _deviceHost, tcpPort: _devicePort), isTrue,
          reason: 'attach $i');
      expect(app.deviceConnected, isTrue);
      await app.startProxy(serverPort: 0);
      final port = app.port;
      final client =
          await _Client(await Socket.connect('127.0.0.1', port)).handshake();
      expect(await portOpen(port), isTrue);
      await client.close();
      await app.disconnectDevice();
      expect(app.deviceConnected, isFalse);
      expect(await portOpen(port), isFalse, reason: 'proxy port closed $i');
    }

    // Reboot with the client attached; the client survives and the virtual
    // identity is preserved.
    expect(
        await app.connectTcp(host: _deviceHost, tcpPort: _devicePort), isTrue);
    await app.startProxy(serverPort: 0);
    final port = app.port;
    final client =
        await _Client(await Socket.connect('127.0.0.1', port)).handshake();
    addTearDown(client.close);
    client.send([cmdRunCliCommand, ...utf8.encode('reboot')]);
    final reply = await client.next();
    expect(reply[0], respCodeCliReply);
    await Future<void>.delayed(const Duration(seconds: 15));
    client.send([
      cmdAppStart,
      3,
      0,
      0,
      0,
      0,
      0,
      0,
      ...utf8.encode('TCP-LIFECYCLE'),
      0,
    ]);
    final self = await client.next();
    expect(self[0], respCodeSelfInfo);
    expect(String.fromCharCodes(self.sublist(58).takeWhile((b) => b != 0)),
        'MeshChameleon');
    expect(app.deviceConnected, isTrue);
  });
}

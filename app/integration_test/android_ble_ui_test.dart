// Android UI/BLE/foreground-service test.
//
// Real BLE scan + attach through the actual ConnectScreen, real AppState, real
// foreground service, and a real local TCP proxy. With BACKGROUND_SECONDS > 0
// it prints BACKGROUND_READY and keeps the app alive while the host backgrounds
// the phone and exercises the proxy.
//
//   flutter test integration_test/android_ble_ui_test.dart -d <device> \
//     --dart-define=BLE_NAME=<advertised name substring>
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/main.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/network_connection_store.dart';
import 'package:meshchameleon/services/session_store.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

const _bleName = String.fromEnvironment('BLE_NAME');
const _proxyPort = int.fromEnvironment('PROXY_PORT', defaultValue: 5221);
const _backgroundSeconds =
    int.fromEnvironment('BACKGROUND_SECONDS', defaultValue: 0);
const _testFw13 = bool.fromEnvironment('TEST_FW13');

void _stage(String text) {
  debugPrint('STAGE $text');
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  throw TimeoutException('condition not met');
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)));
  }
  throw TimeoutException('widget not found: $finder');
}

Future<void> _handshake(int port) async {
  final socket = await Socket.connect('127.0.0.1', port,
      timeout: const Duration(seconds: 5));
  final client = _FramedClient(socket);
  try {
    client.send([cmdDeviceQuery, appProtocolVersion]);
    expect((await client.next())[0], respCodeDeviceInfo);
    client.send([cmdAppStart, appProtocolVersion]);
    expect((await client.next())[0], respCodeSelfInfo);
  } finally {
    await client.close();
  }
}

Future<String> _cli(int port, String command) async {
  final socket = await Socket.connect('127.0.0.1', port,
      timeout: const Duration(seconds: 5));
  final client = _FramedClient(socket);
  try {
    client.send([cmdDeviceQuery, appProtocolVersion]);
    await client.next();
    client.send([cmdAppStart, appProtocolVersion]);
    await client.next();
    client.send([cmdRunCliCommand, ...utf8.encode(command)]);
    final frame = await client.next();
    expect(frame[0], respCodeCliReply);
    return utf8.decode(frame.sublist(1));
  } finally {
    await client.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real BLE UI attach, proxy, and app background survival',
      (tester) async {
    if (_bleName.isEmpty) {
      fail('Set BLE_NAME to the advertised companion name substring.');
    }
    _stage('start');
    final tmp = await getTemporaryDirectory();
    final dir = Directory(
        '${tmp.path}/mesh_ble_ui_${DateTime.now().microsecondsSinceEpoch}');
    await dir.create(recursive: true);
    final identityStore = IdentityStore();
    final app = AppState(
      repository: IdentityRepository(
        supportDirectory: dir,
        secureStore: identityStore,
      ),
      sessionStore: SessionStore(file: File('${dir.path}/session.json')),
      networkConnectionStore:
          NetworkConnectionStore(file: File('${dir.path}/history.json')),
      capabilities: DeviceCapabilities.current(),
    );
    final ids = <String>[];
    addTearDown(() async {
      await app.disconnectDevice();
      await app.manager?.dispose();
      for (final id in ids) {
        await identityStore.deleteById(id);
      }
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    _stage('loading identities');
    await tester.runAsync(() async {
      await app.loadIdentities().timeout(const Duration(seconds: 30));
      final extra = await app.createIdentity(name: 'Android HIL 2');
      ids.addAll(app.identities.map((i) => i.id));
      expect(extra, isNotNull);
      expect(await app.setProxyPort(_proxyPort), isTrue);
    });
    _stage('identities loaded');

    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: const MaterialApp(
        home: HomeScreen(),
      ),
    ));
    await tester.pump(const Duration(seconds: 1));
    _stage('home pumped');
    expect(find.text('Device link'), findsOneWidget);

    // Real UI: open the connect screen, scan, and tap the named companion.
    _stage('open connect');
    await tester.tap(find.text('Device link'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Connect device'), findsOneWidget);
    _stage('bluetooth tab');
    await tester.tap(find.text('Bluetooth'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Scan for MeshCore devices'), findsOneWidget);
    _stage('scan tap');
    await tester.tap(find.text('Scan for MeshCore devices'));
    final target = find.textContaining(_bleName);
    await _pumpUntilFound(tester, target, timeout: const Duration(seconds: 25));
    _stage('scan match');
    debugPrint('SCAN_MATCH $_bleName');
    await tester.tap(target.first);
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (DateTime.now().isBefore(deadline) &&
          (!app.deviceConnected || app.busy)) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    });
    await tester.pump(const Duration(seconds: 2));
    expect(app.deviceConnected, isTrue);
    expect(app.deviceLabel, contains(_bleName));
    expect(find.text('Device link'), findsOneWidget,
        reason: 'connect screen should pop back to home');
    expect(app.identities.length, 2);
    expect(app.manager!.runtimes.where((r) => r.live).length, 2);
    debugPrint('BLE_UI_ATTACH_OK label=${app.deviceLabel} '
        'live=${app.manager!.runtimes.where((r) => r.live).length}');
    expect(await FlutterForegroundTask.isRunningService, isTrue);
    debugPrint('FGS_RUNNING true');

    await tester.tap(find.widgetWithText(SwitchListTile, 'Proxy server'));
    await _waitFor(tester, () => app.proxyStatus == ProxyStatus.running,
        timeout: const Duration(seconds: 15));
    expect(app.port, _proxyPort);
    await tester.runAsync(() => _handshake(_proxyPort));
    debugPrint('PROXY_STARTED port=${app.port}');

    if (_testFw13) {
      final physical = await tester.runAsync(() => app.link!.deviceInfo());
      expect(physical!.firmwareVerCode, 13);
      final virtualName =
          await tester.runAsync(() => _cli(_proxyPort, 'get name'));
      final physicalCli =
          await tester.runAsync(() => _cli(_proxyPort, 'get radio'));
      debugPrint('FW13 physical=${physical.firmwareVerCode} '
          'virtual="$virtualName" physicalCli="$physicalCli"');
      expect(virtualName, contains('MeshChameleon'));
      expect(physicalCli, contains('Error: unsupported'));
      debugPrint('FW13_GATING_OK');
    }

    final pubkey = bytesToHex(app.identity!.publicKey);
    debugPrint('APP_PUBKEY $pubkey');
    debugPrint('BACKGROUND_READY seconds=$_backgroundSeconds');

    if (_backgroundSeconds > 0) {
      for (var i = 0; i < _backgroundSeconds; i += 10) {
        await tester
            .runAsync(() => Future<void>.delayed(const Duration(seconds: 10)));
        debugPrint('BACKGROUND_HEARTBEAT t=${i + 10} '
            'connected=${app.deviceConnected} '
            'queued=${app.node?.queuedDirectCount ?? -1}');
      }
      debugPrint('BACKGROUND_DONE connected=${app.deviceConnected} '
          'queued=${app.node?.queuedDirectCount ?? -1} '
          'proxy=${app.proxyStatus.name}');
    }

    // A second local handshake after the background interval proves the
    // listener and active identity survived.
    await tester.runAsync(() => _handshake(_proxyPort));
    debugPrint('POST_BACKGROUND_HANDSHAKE_OK');
    await tester.runAsync(() async {
      await app.stopProxy();
      await app.disconnectDevice();
    });
    await tester.pump(const Duration(seconds: 1));
    expect(await FlutterForegroundTask.isRunningService, isFalse);
    debugPrint('ANDROID_BLE_UI_OK');
  }, timeout: const Timeout(Duration(minutes: 8)));
}

class _FramedClient {
  _FramedClient(this.socket) {
    _sub = socket.listen((data) {
      for (final frame in _codec.ingest(data)) {
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).complete(frame);
        } else {
          _buffer.add(frame);
        }
      }
    });
  }

  final Socket socket;
  final SerialFrameCodec _codec = SerialFrameCodec.bidirectional();
  late final StreamSubscription<List<int>> _sub;
  final List<Uint8List> _buffer = [];
  final List<Completer<Uint8List>> _waiters = [];

  void send(List<int> payload) {
    socket.add(_codec.encodeFrame(payload, prefix: frameInboundPrefix));
  }

  Future<Uint8List> next() {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    final c = Completer<Uint8List>();
    _waiters.add(c);
    return c.future.timeout(const Duration(seconds: 10));
  }

  Future<void> close() async {
    await _sub.cancel();
    await socket.close();
  }
}

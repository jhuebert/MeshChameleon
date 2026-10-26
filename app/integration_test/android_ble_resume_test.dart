// Android BLE auto-resume test: persist a BLE session with auto-resume, tear
// down the app state, and restore it into a fresh AppState.
//
//   flutter test integration_test/android_ble_resume_test.dart -d <device> \
//     --dart-define=BLE_NAME=<advertised name substring>
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/services/ble_device_link.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/network_connection_store.dart';
import 'package:meshchameleon/services/session_store.dart';
import 'package:path_provider/path_provider.dart';

const _bleName = String.fromEnvironment('BLE_NAME');
const _proxyPort = int.fromEnvironment('PROXY_PORT', defaultValue: 5225);

Future<ScanResult> _scanFor(String needle) async {
  final found = <String, ScanResult>{};
  final sub = FlutterBluePlus.scanResults.listen((results) {
    for (final r in results) {
      if (r.device.platformName.isNotEmpty) found[r.device.platformName] = r;
    }
  });
  await FlutterBluePlus.startScan(
    withServices: [MeshCoreUuids.serviceGuid],
    timeout: const Duration(seconds: 20),
    androidScanMode: AndroidScanMode.lowLatency,
  );
  await FlutterBluePlus.isScanning
      .where((s) => !s)
      .first
      .timeout(const Duration(seconds: 30), onTimeout: () => false);
  await sub.cancel();
  final matches = found.entries.where(
    (e) => e.key.toLowerCase().contains(needle.toLowerCase()),
  );
  if (matches.isEmpty) {
    throw StateError('No BLE match for "$needle" in ${found.keys.toList()}');
  }
  return matches.first.value;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('BLE auto-resume reconnects and restarts the proxy',
      (tester) async {
    if (_bleName.isEmpty) {
      fail('Set BLE_NAME to the advertised companion name substring.');
    }
    final tmp = await getTemporaryDirectory();
    final dir = Directory(
        '${tmp.path}/mesh_ble_resume_${DateTime.now().microsecondsSinceEpoch}');
    await dir.create(recursive: true);
    final store = IdentityStore();
    final repository = IdentityRepository(
      supportDirectory: dir,
      secureStore: store,
    );
    final sessionStore = SessionStore(file: File('${dir.path}/session.json'));
    final historyStore =
        NetworkConnectionStore(file: File('${dir.path}/history.json'));
    AppState makeApp() => AppState(
          repository: repository,
          identityStore: store,
          sessionStore: sessionStore,
          networkConnectionStore: historyStore,
          capabilities: DeviceCapabilities.current(),
          reconnectDelay: const Duration(seconds: 2),
        );
    var app = makeApp();
    AppState? app2;
    final ids = <String>[];
    addTearDown(() async {
      await app.disconnectDevice();
      await app2?.disconnectDevice();
      await app.manager?.dispose();
      await app2?.manager?.dispose();
      for (final id in ids) {
        try {
          await store.deleteById(id);
        } catch (_) {}
      }
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    await tester.runAsync(() async {
      await app.loadIdentities();
      ids.addAll(app.identities.map((i) => i.id));
      expect(await app.setProxyPort(_proxyPort), isTrue);
    });
    final scan = await _scanFor(_bleName);
    expect(await app.connectBle(scan.device), isTrue);
    await tester.runAsync(() => app.startProxy(serverPort: _proxyPort));
    expect(app.proxyStatus, ProxyStatus.running);
    final key = bytesToHex(app.identity!.publicKey);
    await tester.runAsync(() => app.setAutoResume(true));
    final saved = app.lastSession;
    expect(saved?.kind.name, 'ble');
    expect(saved?.bleRemoteId, isNotNull);
    debugPrint('SAVED_SESSION kind=${saved?.kind.name} '
        'ble=${saved?.bleRemoteId} port=${saved?.proxyPort} auto=${saved?.autoResume}');
    await tester.runAsync(() => app.disconnectDevice());
    expect(app.deviceConnected, isFalse);

    app2 = makeApp();
    await tester.runAsync(() => app2!.loadIdentities());
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (DateTime.now().isBefore(deadline) &&
        (!app2.deviceConnected || app2.proxyStatus != ProxyStatus.running)) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
    }
    expect(app2.deviceConnected, isTrue);
    expect(app2.proxyStatus, ProxyStatus.running);
    expect(bytesToHex(app2.identity!.publicKey), key);
    final socket = await Socket.connect('127.0.0.1', _proxyPort);
    final client = _FramedClient(socket);
    try {
      client.send([cmdDeviceQuery, appProtocolVersion]);
      await client.next();
      client.send([cmdAppStart, appProtocolVersion]);
      final self = await client.next();
      expect(self.sublist(4, 36), hexToBytes(key));
    } finally {
      await client.close();
    }
    debugPrint('BLE_AUTO_RESUME_OK key=$key label=${app2.deviceLabel}');
  }, timeout: const Timeout(Duration(minutes: 2)));
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
    return c.future.timeout(const Duration(seconds: 20));
  }

  Future<void> close() async {
    await _sub.cancel();
    await socket.close();
  }
}

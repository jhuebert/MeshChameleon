// Android BLE multi-identity switch test.
//
//   flutter test integration_test/android_ble_identity_switch_test.dart \
//     -d <device> --dart-define=BLE_NAME=<advertised name substring>
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
const _proxyPort = int.fromEnvironment('PROXY_PORT', defaultValue: 5226);

Future<BluetoothDevice> _scanFor(String needle) async {
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
  return matches.first.value.device;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('BLE identity switch keeps the listener and serves the new key',
      (tester) async {
    if (_bleName.isEmpty) {
      fail('Set BLE_NAME to the advertised companion name substring.');
    }
    final tmp = await getTemporaryDirectory();
    final dir = Directory(
        '${tmp.path}/mesh_ble_switch_${DateTime.now().microsecondsSinceEpoch}');
    await dir.create(recursive: true);
    final store = IdentityStore();
    final app = AppState(
      repository: IdentityRepository(
        supportDirectory: dir,
        secureStore: store,
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
        try {
          await store.deleteById(id);
        } catch (_) {}
      }
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    await tester.runAsync(() async {
      await app.loadIdentities();
      final second = await app.createIdentity(name: 'Android BLE 2');
      expect(second, isNotNull);
      ids.addAll(app.identities.map((i) => i.id));
      expect(await app.setProxyPort(_proxyPort), isTrue);
    });
    final device = await _scanFor(_bleName);
    expect(await app.connectBle(device), isTrue);
    await tester.runAsync(() => app.startProxy(serverPort: _proxyPort));
    expect(app.proxyStatus, ProxyStatus.running);
    expect(app.manager!.runtimes.where((r) => r.live).length, 2);
    final firstKey = bytesToHex(app.identity!.publicKey);
    final second =
        app.identities.firstWhere((i) => i.id != app.activeIdentityId);
    final secondKey = app.manager!.runtimes
        .firstWhere((r) => r.record.id == second.id)
        .identity!
        .publicKey;

    final firstClient =
        _FramedClient(await Socket.connect('127.0.0.1', _proxyPort));
    try {
      firstClient.send([cmdDeviceQuery, appProtocolVersion]);
      await firstClient.next();
      firstClient.send([cmdAppStart, appProtocolVersion]);
      final self = await firstClient.next();
      expect(self.sublist(4, 36), hexToBytes(firstKey));
    } finally {
      await firstClient.close();
    }

    expect(await app.activateIdentity(second.id), isTrue);
    expect(app.activeIdentityId, second.id);
    expect(app.proxyStatus, ProxyStatus.running);
    final secondClient =
        _FramedClient(await Socket.connect('127.0.0.1', _proxyPort));
    try {
      secondClient.send([cmdDeviceQuery, appProtocolVersion]);
      await secondClient.next();
      secondClient.send([cmdAppStart, appProtocolVersion]);
      final self = await secondClient.next();
      expect(self.sublist(4, 36), secondKey);
    } finally {
      await secondClient.close();
    }
    debugPrint('BLE_IDENTITY_SWITCH_OK first=$firstKey '
        'second=${bytesToHex(secondKey)} live=2');
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

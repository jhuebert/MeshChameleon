// Android BLE battery test: raw BLE voltage, app-facing GET_BATT_AND_STORAGE
// (virtual 4096 KiB), and freshness/refresh across one or more companions.
//
//   flutter test integration_test/android_ble_battery_test.dart -d <device> \
//     --dart-define=BLE_NAMES=MeshCore-aaaa,MeshCore-bbbb
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

const _targetNames = String.fromEnvironment('BLE_NAMES');

List<String> _targetsFromEnv() => _targetNames
    .split(',')
    .map((name) => name.trim())
    .where((name) => name.isNotEmpty)
    .toList();

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

Future<Uint8List> _batteryFrame(int port) async {
  final socket = await Socket.connect('127.0.0.1', port,
      timeout: const Duration(seconds: 5));
  final client = _FramedClient(socket);
  try {
    client.send([cmdDeviceQuery, appProtocolVersion]);
    await client.next();
    client.send([cmdAppStart, appProtocolVersion]);
    await client.next();
    client.send([cmdGetBattAndStorage]);
    final frame = await client.next();
    expect(frame[0], respCodeBattAndStorage);
    return frame;
  } finally {
    await client.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('battery and virtual storage over BLE and proxy', (tester) async {
    final targets = _targetsFromEnv();
    if (targets.isEmpty) {
      fail('Set BLE_NAMES to a comma-separated list of advertised names.');
    }
    final tmp = await getTemporaryDirectory();
    final dir = Directory(
        '${tmp.path}/mesh_ble_batt_${DateTime.now().microsecondsSinceEpoch}');
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
      ids.addAll(app.identities.map((i) => i.id));
    });

    for (var i = 0; i < targets.length; i++) {
      final name = targets[i];
      final port = 5230 + i;
      final scan = await _scanFor(name);
      expect(await app.connectBle(scan.device), isTrue);
      await tester.runAsync(() => app.startProxy(serverPort: port));
      expect(app.proxyStatus, ProxyStatus.running);
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (DateTime.now().isBefore(deadline) &&
            (app.node!.battery.millivolts == 0 || app.batteryStale)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      });
      final raw = await tester.runAsync(() => app.link!.battery());
      expect(raw, isNotNull);
      expect(raw!.millivolts, greaterThan(3500), reason: '$name voltage');
      final frame = await _batteryFrame(port);
      final data = ByteData.sublistView(frame);
      final proxyMv = data.getUint16(1, Endian.little);
      final usedKb = data.getUint32(3, Endian.little);
      final totalKb = data.getUint32(7, Endian.little);
      final appMv = app.node!.battery.millivolts;
      debugPrint('BATTERY_CASE name=$name raw=${raw.millivolts}mV '
          'proxy=$proxyMv used=${usedKb}KiB total=${totalKb}KiB '
          'app=$appMv age=${app.batterySampleAgeSeconds}s '
          'stale=${app.batteryStale} diag="${app.batteryDiagnostic}"');
      expect((proxyMv - raw.millivolts).abs(), lessThanOrEqualTo(20));
      expect(appMv, greaterThan(3500));
      expect(app.batteryStale, isFalse);
      expect(usedKb, greaterThan(0));
      expect(totalKb, 4096, reason: 'virtual storage, not T1000e 100 KiB');

      // Cross the 10s freshness window; the next request must refresh from the
      // physical BLE link, not replay a fabricated timestamp.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 11));
      });
      expect(app.batteryStale, isTrue);
      final frame2 = await _batteryFrame(port);
      final data2 = ByteData.sublistView(frame2);
      final proxyMv2 = data2.getUint16(1, Endian.little);
      final age2 = app.batterySampleAgeSeconds;
      debugPrint('BATTERY_REFRESH name=$name proxy=$proxyMv2 '
          'age=${age2}s stale=${app.batteryStale}');
      expect((proxyMv2 - raw.millivolts).abs(), lessThanOrEqualTo(30));
      expect(app.batteryStale, isFalse);
      expect(age2, isNotNull);
      expect(age2!, lessThan(10));

      await tester.runAsync(() async {
        await app.stopProxy();
        await app.disconnectDevice();
      });
    }
    debugPrint('BLE_BATTERY_OK targets=${targets.length}');
  }, timeout: const Timeout(Duration(minutes: 4)));
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
    return c.future.timeout(const Duration(seconds: 15));
  }

  Future<void> close() async {
    await _sub.cancel();
    await socket.close();
  }
}

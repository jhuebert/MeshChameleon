// Read nc1v's current (saved) radio settings on a fresh connection. Temporary.
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:meshchameleon/services/ble_device_link.dart';

Future<BluetoothDevice> _scanFor(String needle) async {
  final found = <String, ScanResult>{};
  final sub = FlutterBluePlus.scanResults.listen((results) {
    for (final r in results) {
      final name = r.device.platformName;
      if (name.isNotEmpty) found[name] = r;
    }
  });
  await FlutterBluePlus.startScan(
    withServices: [MeshCoreUuids.serviceGuid],
    timeout: const Duration(seconds: 20),
    androidScanMode: AndroidScanMode.lowLatency,
  );
  await FlutterBluePlus.isScanning
      .where((s) => s == false)
      .first
      .timeout(const Duration(seconds: 30), onTimeout: () => false);
  await sub.cancel();
  final match =
      found.entries.where((e) => e.key.toLowerCase().contains(needle.toLowerCase()));
  if (match.isEmpty) {
    if (found.length == 1) return found.values.first.device;
    throw StateError('no match');
  }
  return match.first.value.device;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('read nc1v params', (tester) async {
    final device = await _scanFor('nc1v');
    final link = BleDeviceLink(device: device, onLog: (m) => debugPrint('[ble] $m'));
    await link.connect();
    addTearDown(link.disconnect);
    final p = await link.radioParams();
    debugPrint('nc1v params: freq=${p.frequencyHz} bw=${p.bandwidthHz} '
        'sf=${p.spreadingFactor} cr=${p.codingRate}');
    expect(p.frequencyHz, 910525000);
    expect(p.bandwidthHz, 62500);
    expect(p.spreadingFactor, 7);
    expect(p.codingRate, 8);
  });
}

// Android BLE NUS scan: list every MeshCore companion currently advertising,
// without connecting or writing anything.
//
//   flutter test integration_test/android_ble_scan_test.dart -d <device>

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:meshchameleon/services/ble_device_link.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scan and list MeshCore BLE companions', (tester) async {
    final found = <String, ScanResult>{};
    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final name = r.device.platformName;
        if (name.isNotEmpty) found[name] = r;
      }
    });
    await FlutterBluePlus.startScan(
      withServices: [MeshCoreUuids.serviceGuid],
      timeout: const Duration(seconds: 15),
      androidScanMode: AndroidScanMode.lowLatency,
    );
    await FlutterBluePlus.isScanning
        .where((s) => !s)
        .first
        .timeout(const Duration(seconds: 25), onTimeout: () => false);
    await sub.cancel();
    for (final entry in found.entries) {
      final r = entry.value;
      debugPrint('BLE_SCAN platform="${r.device.platformName}" '
          'adv="${r.advertisementData.advName}" id=${r.device.remoteId} '
          'rssi=${r.rssi} services=${r.advertisementData.serviceUuids} '
          'serviceData=${r.advertisementData.serviceData.keys.toList()}');
    }
    debugPrint('BLE_SCAN_COUNT ${found.length}');
    expect(found, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 1)));
}

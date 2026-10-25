// Restore nc1v to its live-mesh radio settings and reboot the device so the
// change takes effect. Temporary; not part of the default gate.
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

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

  testWidgets('restore nc1v radio settings', (tester) async {
    final device = await _scanFor('nc1v');
    final link = BleDeviceLink(device: device, onLog: (m) => debugPrint('[ble] $m'));
    await link.connect();
    addTearDown(link.disconnect);

    debugPrint('before: ${await link.radioParams()}');
    const restore = RadioParams(
      frequencyHz: 910525000,
      bandwidthHz: 62500,
      spreadingFactor: 7,
      codingRate: 8,
    );
    await link.setRadioParams(restore);
    await link.reboot(); // firmware reboots to apply the saved radio prefs
    debugPrint('restored to 910.525/62.5/7/8 and rebooted the device');
  });
}

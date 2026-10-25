// Temporary hardware validation (not part of the default gate).
//
// Tunes the BLE companion to the repeater's channel and *listens*, printing any
// advertiser contacts processed by the node. Used with a concurrent loop that
// makes the repeater flood adverts, to test the repeater->companion RF path.
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'package:meshchameleon/services/ble_device_link.dart';

const _bleName = String.fromEnvironment('BLE_NAME', defaultValue: 'nc1v');

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
    throw StateError('no match for "$needle"');
  }
  return match.first.value.device;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('listen for the repeater advert on channel 926.0/125/8/5',
      (tester) async {
    final device = await _scanFor(_bleName);
    final link = BleDeviceLink(device: device, onLog: (m) => debugPrint('[ble] $m'));
    await link.connect();
    addTearDown(link.disconnect);

    final info = await link.deviceInfo();
    final orig = await link.radioParams();
    const target = RadioParams(
      frequencyHz: 926000000,
      bandwidthHz: 125000,
      spreadingFactor: 8,
      codingRate: 5,
    );

    final identity = await LocalIdentity.generate();
    final node = MeshNode(
      identity: identity,
      link: link,
      physical: PhysicalCapabilities.fromDeviceInfo(info),
      store: InMemoryNodeStore(),
    );
    await node.load();
    node.syncRadioParams(orig);
    node.start();
    addTearDown(node.stop);

    try {
      await link.setRadioParams(target);
      await Future<void>.delayed(const Duration(seconds: 1));
      final applied = await link.radioParams();
      debugPrint('listening on freq=${applied.frequencyHz} bw=${applied.bandwidthHz} '
          'sf=${applied.spreadingFactor} cr=${applied.codingRate}');
      for (var i = 0; i < 24; i++) {
        await Future<void>.delayed(const Duration(seconds: 5));
        final names = node.contacts.map((c) => c.name).toList();
        debugPrint('t=${(i + 1) * 5}s contacts=${node.contacts.length} $names');
      }
    } finally {
      debugPrint('restoring nc1v radio');
      await link.setRadioParams(orig);
    }
  });
}

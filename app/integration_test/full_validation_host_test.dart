// Temporary hardware harness: tune nc1v to the isolated channel, start the
// proxy on a fixed port bound to all interfaces, and hold it open so a
// laptop-side meshcore_py client can exercise the full command surface.
import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'package:meshchameleon/services/ble_device_link.dart';

const _bleName = String.fromEnvironment('BLE_NAME', defaultValue: 'nc1v');
const _port = int.fromEnvironment('PROXY_PORT', defaultValue: 5000);
const _holdSecs = int.fromEnvironment('HOLD_SECS', defaultValue: 300);
const _repeaterPubkeyHex =
    '70A3E4B4B9F8A56A769D730608870A0507D30D7069B83691C2324636C5E5EB56';

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

  testWidgets('host proxy for the meshcore_py suite', (tester) async {
    final device = await _scanFor(_bleName);
    final link = BleDeviceLink(device: device, onLog: (m) => debugPrint('[ble] $m'));
    for (var i = 0; i < 5; i++) {
      try {
        await link.connect();
        break;
      } catch (e) {
        debugPrint('connect attempt $i failed: $e');
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    if (link.currentState != LinkState.connected) {
      fail('could not connect to $_bleName');
    }
    addTearDown(link.disconnect);

    final info = await link.deviceInfo();
    final orig = await link.radioParams();
    debugPrint('orig: freq=${orig.frequencyHz} bw=${orig.bandwidthHz} '
        'sf=${orig.spreadingFactor} cr=${orig.codingRate}');

    final identity = await LocalIdentity.generate();
    final node = MeshNode(
      identity: identity,
      link: link,
      deviceInfo: info,
      store: InMemoryNodeStore(),
    );
    await node.load();
    node.syncRadioParams(orig);
    node.start();
    addTearDown(node.stop);

    const target = RadioParams(
      frequencyHz: 926000000,
      bandwidthHz: 125000,
      spreadingFactor: 8,
      codingRate: 5,
    );
    await link.setRadioParams(target);
    await link.reboot();
    debugPrint('rebooted nc1v; reconnecting ...');
    await Future<void>.delayed(const Duration(seconds: 6));
    for (var i = 0; i < 12 && link.currentState != LinkState.connected; i++) {
      try {
        await link.connect();
      } catch (e) {
        debugPrint('connect: $e');
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    final applied = await link.radioParams();
    debugPrint('applied: freq=${applied.frequencyHz} bw=${applied.bandwidthHz} '
        'sf=${applied.spreadingFactor} cr=${applied.codingRate}');
    node.syncRadioParams(applied);

    // Add the T1000-E repeater as a contact so the client can target it.
    final repeater = Uint8List.fromList([
      for (var i = 0; i + 1 < _repeaterPubkeyHex.length; i += 2)
        int.parse(_repeaterPubkeyHex.substring(i, i + 2), radix: 16),
    ]);
    node.addUpdateContact(Contact(
      publicKey: repeater,
      name: 't1000-e Repeater',
      advType: advTypeRepeater,
    ));

    final server = CompanionServer(
      bridge: node,
      config: const CompanionServerConfig(port: _port),
      onLog: (m) => debugPrint('[server] $m'),
    );
    await server.start();
    addTearDown(server.stop);
    debugPrint('READY on 0.0.0.0:$_port (identity='
        '${bytesToHex(identity.publicKey).substring(0, 12)})');

    for (var i = 0; i < _holdSecs; i += 15) {
      await Future<void>.delayed(const Duration(seconds: 15));
      debugPrint('t=${i + 15}s');
    }

    debugPrint('restoring nc1v to ${orig.frequencyHz} ...');
    try {
      await link.setRadioParams(orig);
      await link.reboot();
    } catch (e) {
      debugPrint('restore failed: $e');
    }
  });
}

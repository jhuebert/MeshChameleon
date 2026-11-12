import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_device_link.dart';

/// Minimal seam over BLE scanning so the connect screen can be exercised
/// without the plugin (scan start failure, timeout, results, stop).
///
/// The plugin reports the real scan lifecycle; the screen mirrors it instead
/// of assuming the future duration.
abstract class ScanSession {
  /// Latest advertisement results, emitted during and after a scan.
  Stream<List<ScanResult>> get results;

  /// Plugin-reported scanning state (false once the 15 s timeout elapses).
  Stream<bool> get isScanning;

  Future<void> start();
  Future<void> stop();
}

/// Production session backed by flutter_blue_plus.
class BleScanSession implements ScanSession {
  const BleScanSession();

  @override
  Stream<List<ScanResult>> get results => MeshCoreUuids.scanResults;

  @override
  Stream<bool> get isScanning => FlutterBluePlus.isScanning;

  @override
  Future<void> start() => MeshCoreUuids.startScan();

  @override
  Future<void> stop() => FlutterBluePlus.stopScan();
}

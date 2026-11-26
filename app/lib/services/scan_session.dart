import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_device_link.dart';

/// A scan-start failure with copy that is safe to show on the connect screen.
class ScanStartException implements Exception {
  const ScanStartException(this.message);

  final String message;

  @override
  String toString() => message;
}

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
  const BleScanSession({
    this.adapterStates,
    this.startScan,
    this.adapterTimeout = const Duration(seconds: 5),
  });

  /// Overridable in tests; production uses the plugin's adapter stream.
  final Stream<BluetoothAdapterState>? adapterStates;

  /// Overridable in tests; production uses [MeshCoreUuids.startScan].
  final Future<void> Function()? startScan;

  /// How long to wait for the adapter to settle before reporting failure.
  final Duration adapterTimeout;

  @override
  Stream<List<ScanResult>> get results => MeshCoreUuids.scanResults;

  @override
  Stream<bool> get isScanning => FlutterBluePlus.isScanning;

  @override
  Future<void> start() async {
    // CoreBluetooth is asynchronous: on macOS the first scan in a session can
    // be issued while the adapter is still `unknown`, which the plugin rejects.
    // Wait for a settled state so the first click works, not just the retry.
    final state = await (adapterStates ?? FlutterBluePlus.adapterState)
        .firstWhere(_isSettled, orElse: () => BluetoothAdapterState.unknown)
        .timeout(adapterTimeout,
            onTimeout: () => BluetoothAdapterState.unknown);
    switch (state) {
      case BluetoothAdapterState.on:
        await (startScan ?? MeshCoreUuids.startScan)();
        break;
      case BluetoothAdapterState.unauthorized:
        throw const ScanStartException(
          'Bluetooth permission is off for MeshChameleon. Allow it in System '
          'Settings > Privacy & Security > Bluetooth, then scan again.',
        );
      case BluetoothAdapterState.off:
        throw const ScanStartException(
          'Bluetooth is off. Turn it on, then scan again.',
        );
      case BluetoothAdapterState.unavailable:
        throw const ScanStartException(
          'Bluetooth is not available on this device. Use TCP / Wi-Fi instead.',
        );
      default:
        throw const ScanStartException(
          'Bluetooth is still starting up. Try again in a moment.',
        );
    }
  }

  static bool _isSettled(BluetoothAdapterState state) =>
      state == BluetoothAdapterState.on ||
      state == BluetoothAdapterState.off ||
      state == BluetoothAdapterState.unauthorized ||
      state == BluetoothAdapterState.unavailable;

  @override
  Future<void> stop() => FlutterBluePlus.stopScan();
}

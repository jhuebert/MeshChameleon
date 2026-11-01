import 'dart:io' show Platform;

/// Which device transports this build can actually offer.
///
/// BLE is only implemented on the mobile platforms we ship: desktop builds have
/// no `flutter_blue_plus` implementation, so their UI must not touch it at all
/// (even reading `FlutterBluePlus.scanResults` reaches the plugin). The
/// simulated companion is in-memory and available everywhere.
class DeviceCapabilities {
  const DeviceCapabilities({
    required this.supportsBle,
  });

  /// Capabilities of the platform this process is running on.
  factory DeviceCapabilities.current() => DeviceCapabilities(
        supportsBle: Platform.isAndroid || Platform.isIOS,
      );

  /// Whether this platform has a BLE plugin implementation.
  final bool supportsBle;
}

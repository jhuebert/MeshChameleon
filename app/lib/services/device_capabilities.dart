import 'dart:io' show Platform;

/// Which device transports this build can actually offer.
///
/// `flutter_blue_plus` has implementations for Android, iOS, macOS and Linux.
/// Windows has none, so its UI must not touch BLE at all (even reading
/// `FlutterBluePlus.scanResults` reaches the plugin). The simulated companion
/// is in-memory and available everywhere.
class DeviceCapabilities {
  const DeviceCapabilities({
    required this.supportsBle,
  });

  /// Host probe, overridable in tests so the platform matrix can be checked on
  /// any host. Widget tests inject [DeviceCapabilities] directly.
  static bool Function() platformProbe = () =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isLinux;

  /// Capabilities of the platform this process is running on.
  factory DeviceCapabilities.current() => DeviceCapabilities(
        supportsBle: platformProbe(),
      );

  /// Whether this platform has a BLE plugin implementation.
  final bool supportsBle;
}

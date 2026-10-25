import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kReleaseMode;

/// Which device transports this build can actually offer.
///
/// BLE is only implemented on the mobile platforms we ship: desktop builds have
/// no `flutter_blue_plus` implementation, so their UI must not touch it at all
/// (even reading `FlutterBluePlus.scanResults` reaches the plugin). The
/// simulated companion is a development aid and is kept out of release builds.
class DeviceCapabilities {
  const DeviceCapabilities({
    required this.supportsBle,
    required this.supportsSimulatedCompanion,
  });

  /// Capabilities of the platform this process is running on.
  factory DeviceCapabilities.current() => DeviceCapabilities(
        supportsBle: Platform.isAndroid || Platform.isIOS,
        supportsSimulatedCompanion: !kReleaseMode,
      );

  /// Whether this platform has a BLE plugin implementation.
  final bool supportsBle;

  /// Whether the in-memory simulated companion may be offered.
  final bool supportsSimulatedCompanion;
}

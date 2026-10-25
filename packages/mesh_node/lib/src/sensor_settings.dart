/// Injectable virtual sensor-settings provider.
///
/// Custom variables are sensor settings, not an arbitrary string dictionary.
/// A provider declares the keys it actually implements and validates values.
/// Accepted settings are persisted in [NodeState.customSettings].
abstract class VirtualSensorSettingsProvider {
  const VirtualSensorSettingsProvider();

  /// Defaults presented before any persisted value exists.
  Map<String, String> get initialSettings => const <String, String>{};

  /// Whether this provider implements [key].
  bool supports(String key);

  /// Validate/normalize [value] for [key], or return `null` to reject it.
  String? normalize(String key, String value);
}

/// Default provider: this build has no virtual GPS/environment hardware, so it
/// exposes zero settings and rejects every SET with ERR6.
class EmptyVirtualSensorSettingsProvider
    extends VirtualSensorSettingsProvider {
  const EmptyVirtualSensorSettingsProvider();

  @override
  bool supports(String key) => false;

  @override
  String? normalize(String key, String value) => null;
}

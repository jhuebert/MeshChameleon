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

  /// Notify the provider that the node's accepted settings changed.
  ///
  /// Called after load, start, SET, and reset so hosts can react (for example
  /// starting or stopping a location timer). [normalize] is also called while
  /// loading persisted state and must stay free of side effects.
  void onSettingsChanged(Map<String, String> settings) {}
}

/// Default provider: this build has no virtual GPS/environment hardware, so it
/// exposes zero settings and rejects every SET with ERR6.
class EmptyVirtualSensorSettingsProvider extends VirtualSensorSettingsProvider {
  const EmptyVirtualSensorSettingsProvider();

  @override
  bool supports(String key) => false;

  @override
  String? normalize(String key, String value) => null;
}

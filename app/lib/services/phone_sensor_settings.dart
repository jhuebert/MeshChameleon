import 'package:mesh_node/mesh_node.dart';

/// Virtual GPS settings backing one identity.
///
/// Values are the same `gps` and `gps_interval` custom variables a companion
/// client writes, so the client toggle and the app switch share one source of
/// truth. Side effects go through [onChanged] rather than [normalize], which is
/// also called while loading persisted state.
class PhoneSensorSettingsProvider extends VirtualSensorSettingsProvider {
  PhoneSensorSettingsProvider({
    required this.identityId,
    required this.onChanged,
  });

  final String identityId;
  final void Function(String identityId, Map<String, String> settings)
      onChanged;

  static const Map<String, String> initial = {
    'gps': '0',
    'gps_interval': '900',
  };

  static const int minIntervalSeconds = 0;
  static const int maxIntervalSeconds = 86400;

  @override
  Map<String, String> get initialSettings => initial;

  @override
  bool supports(String key) => key == 'gps' || key == 'gps_interval';

  @override
  String? normalize(String key, String value) {
    switch (key) {
      case 'gps':
        final trimmed = value.trim();
        return trimmed == '0' || trimmed == '1' ? trimmed : null;
      case 'gps_interval':
        final seconds = int.tryParse(value.trim());
        if (seconds == null) return null;
        return seconds.clamp(minIntervalSeconds, maxIntervalSeconds).toString();
      default:
        return null;
    }
  }

  /// Forward the node's current settings to the location service.
  void sync(Map<String, String> settings) =>
      onChanged(identityId, Map<String, String>.of(settings));

  @override
  void onSettingsChanged(Map<String, String> settings) => sync(settings);
}

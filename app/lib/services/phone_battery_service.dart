import 'package:battery_plus/battery_plus.dart';

/// Reads the phone's battery percentage for virtual telemetry.
///
/// The platform read is injected so tests do not need a battery channel. The
/// latest successful value is cached for the UI and diagnostics; telemetry
/// still performs a fresh read per request.
class PhoneBatteryService {
  PhoneBatteryService({Future<int> Function()? readLevel})
      : _readLevel = readLevel ?? _platformRead;

  final Future<int> Function() _readLevel;

  int? _lastValue;
  DateTime? _lastReadAt;
  String? _lastError;

  int? get lastValue => _lastValue;
  DateTime? get lastReadAt => _lastReadAt;
  String? get lastError => _lastError;

  Future<int?> read() async {
    try {
      final level = await _readLevel();
      final clamped = level.clamp(0, 100);
      _lastValue = clamped;
      _lastReadAt = DateTime.now();
      _lastError = null;
      return clamped;
    } catch (e) {
      _lastError = '$e';
      return null;
    }
  }

  static Future<int> _platformRead() => Battery().batteryLevel;
}

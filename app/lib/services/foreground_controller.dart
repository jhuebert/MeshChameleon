import 'device_link_phase.dart';
import 'foreground_service.dart';
import 'notification_content.dart';
import 'proxy_status.dart';

/// Foreground-service lifecycle and notification copy.
///
/// The controller keeps the last notification key so chatty manager updates do
/// not rewrite an unchanged notification. All platform calls go through the
/// injected [ForegroundService].
class ForegroundController {
  ForegroundController({
    required this.service,
    required this.identityCount,
    required this.activeName,
    required this.devicePhase,
    required this.deviceConnected,
    required this.proxyStatus,
    required this.port,
    required this.log,
    this.includeLocation = _noLocation,
  });

  static bool _noLocation() => false;

  final ForegroundService service;
  final int Function() identityCount;
  final String? Function() activeName;
  final DeviceLinkPhase Function() devicePhase;
  final bool Function() deviceConnected;
  final ProxyStatus Function() proxyStatus;
  final int Function() port;
  final void Function(String message) log;

  /// Whether location access is currently granted for the `location` type.
  final bool Function() includeLocation;

  bool get includesLocation => service.includesLocation;

  bool _started = false;
  String? _lastKey;

  bool get running => _started;

  NotificationContent content() => buildNotificationContent(
        identityCount: identityCount(),
        activeName: activeName(),
        devicePhase: devicePhase(),
        deviceConnected: deviceConnected(),
        proxyStatus: proxyStatus(),
        port: port(),
      );

  Future<void> start() async {
    if (!service.isSupported) return;
    try {
      final value = content();
      await service.start(
        title: value.title,
        text: value.text,
        includeLocation: includeLocation(),
      );
      _started = true;
      _lastKey = value.key;
    } catch (e) {
      log('Foreground service unavailable: $e');
    }
  }

  Future<void> update() async {
    try {
      final value = content();
      await service.update(title: value.title, text: value.text);
      _lastKey = value.key;
    } catch (e) {
      log('Foreground service update failed: $e');
    }
  }

  /// Update only when the visible copy changed.
  Future<void> updateIfChanged() async {
    final value = content();
    if (_started && value.key != _lastKey) await update();
  }

  /// Re-evaluate the declared service types after a permission change.
  Future<void> refreshServiceTypes() async {
    if (!service.isSupported || !_started) return;
    try {
      final value = content();
      await service.start(
        title: value.title,
        text: value.text,
        includeLocation: includeLocation(),
      );
      _lastKey = value.key;
    } catch (e) {
      log('Foreground service type update failed: $e');
    }
  }

  Future<void> stop() async {
    try {
      await service.stop();
    } catch (_) {
      // The service may already be stopped.
    }
    _started = false;
  }

  void reset() {
    _started = false;
    _lastKey = null;
  }

  /// Returns null when unsupported or the check fails.
  Future<bool?> batteryStatus() async {
    if (!service.isSupported) return null;
    try {
      return await service.isIgnoringBatteryOptimizations();
    } catch (e) {
      log('Battery optimization check failed: $e');
      return null;
    }
  }

  Future<void> openBatterySettings() async {
    if (!service.isSupported) return;
    try {
      await service.openBatteryOptimizationSettings();
    } catch (e) {
      log('Battery optimization settings failed to open: $e');
    }
  }
}

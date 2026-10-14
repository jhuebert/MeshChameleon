import 'dart:io' show Platform;

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps the proxy process alive while the app is backgrounded (M0 shape A).
///
/// The proxy engine (sockets + BLE) runs in the main isolate; this service
/// only holds a persistent notification and prevents the OS from suspending the
/// process. When the service starts, [startCallback] runs in a separate
/// isolate, but for shape A it intentionally does no work there.
class ForegroundService {
  bool _initialized = false;

  bool get _isAndroid => Platform.isAndroid;

  Future<void> initialize() async {
    if (!_isAndroid || _initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'companion_proxy',
        channelName: 'Companion Proxy',
        channelDescription: 'Keeps the device link and proxy server running.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWifiLock: true,
      ),
    );
    _initialized = true;
  }

  Future<void> start({required String title, required String text}) async {
    if (!_isAndroid) return;
    if (!_initialized) await initialize();
    if (await FlutterForegroundTask.isRunningService) {
      await update(title: title, text: text);
      return;
    }
    await FlutterForegroundTask.requestNotificationPermission();
    final result = await FlutterForegroundTask.startService(
      serviceTypes: const [ForegroundServiceTypes.connectedDevice],
      notificationTitle: title,
      notificationText: text,
      callback: startCallback,
    );
    if (result is ServiceRequestFailure) {
      throw StateError('foreground service start failed: ${result.error}');
    }
  }

  Future<void> update({required String title, required String text}) async {
    if (!_isAndroid) return;
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }

  Future<void> stop() async {
    if (!_isAndroid) return;
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.stopService();
  }

  /// Whether the OS has exempted the app from battery optimizations.
  Future<bool> isIgnoringBatteryOptimizations() =>
      FlutterForegroundTask.isIgnoringBatteryOptimizations;

  Future<void> requestBatteryOptimizationExemption() =>
      FlutterForegroundTask.requestIgnoreBatteryOptimization();
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_ProxyTaskHandler());
}

class _ProxyTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }
}

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_foreground_task/flutter_foreground_task_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/services/foreground_service.dart';

void main() {
  late _FakeForegroundPlatform platform;
  late ForegroundService service;

  setUp(() {
    FlutterForegroundTask.resetStatic();
    FlutterForegroundTask.skipServiceResponseCheck = true;
    platform = _FakeForegroundPlatform();
    FlutterForegroundTaskPlatform.instance = platform;
    service = ForegroundService();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    FlutterForegroundTask.resetStatic();
  });

  test('initialize is a one-time no-op outside Android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await service.initialize();
    await service.start(title: 'title', text: 'text');
    await service.update(title: 'title', text: 'text');
    await service.stop();
    expect(platform.calls, isEmpty);
  });

  test('initialize configures the plugin only once', () async {
    await service.initialize();
    await service.initialize();
    expect(FlutterForegroundTask.isInitialized, isTrue);
    expect(platform.calls, isEmpty);
  });

  test('start initializes, requests permission, and starts the service',
      () async {
    await service.start(title: 'MeshChameleon', text: 'Running');
    expect(platform.requestedPermission, isTrue);
    expect(platform.startCalls, 1);
    expect(platform.running, isTrue);
    expect(platform.lastTitle, 'MeshChameleon');
    expect(platform.lastText, 'Running');
  });

  test('start updates an existing service instead of starting it again',
      () async {
    platform.running = true;
    await service.start(title: 'new', text: 'text');
    expect(platform.startCalls, 0);
    expect(platform.updateCalls, 1);
    expect(platform.lastTitle, 'new');
  });

  test('start surfaces plugin failures', () async {
    platform.failStart = true;
    await expectLater(
      service.start(title: 'title', text: 'text'),
      throwsA(isA<StateError>()),
    );
  });

  test('update only runs while the service is running', () async {
    await service.update(title: 'title', text: 'text');
    expect(platform.updateCalls, 0);

    platform.running = true;
    await service.update(title: 'new', text: 'text');
    expect(platform.updateCalls, 1);
  });

  test('stop only runs while the service is running', () async {
    await service.stop();
    expect(platform.stopCalls, 0);

    platform.running = true;
    await service.stop();
    expect(platform.stopCalls, 1);
  });

  test('battery helpers delegate to the plugin', () async {
    platform.ignoringBatteryOptimizations = true;
    expect(await service.isIgnoringBatteryOptimizations(), isTrue);
    expect(await service.openBatteryOptimizationSettings(), isTrue);
    expect(platform.openedBatterySettings, isTrue);
  });

  test('the task handler forwards notification actions to the plugin',
      () async {
    startCallback();
    final handler = platform.taskHandler;
    expect(handler, isNotNull);

    await handler!.onStart(DateTime.now(), TaskStarter.developer);
    handler
      ..onRepeatEvent(DateTime.now())
      ..onNotificationButtonPressed('id')
      ..onNotificationPressed();
    await handler.onDestroy(DateTime.now(), false);

    expect(platform.launchedRoute, '/');
  });
}

class _FakeForegroundPlatform extends FlutterForegroundTaskPlatform {
  final calls = <String>[];
  bool running = false;
  bool failStart = false;
  bool requestedPermission = false;
  bool openedBatterySettings = false;
  bool ignoringBatteryOptimizations = false;
  int startCalls = 0;
  int updateCalls = 0;
  int stopCalls = 0;
  String? lastTitle;
  String? lastText;
  String? launchedRoute;
  TaskHandler? taskHandler;

  @override
  Future<void> startService({
    required AndroidNotificationOptions androidNotificationOptions,
    required IOSNotificationOptions iosNotificationOptions,
    required ForegroundTaskOptions foregroundTaskOptions,
    int? serviceId,
    List<ForegroundServiceTypes>? serviceTypes,
    required String notificationTitle,
    required String notificationText,
    NotificationIcon? notificationIcon,
    List<NotificationButton>? notificationButtons,
    String? notificationInitialRoute,
    Function? callback,
  }) async {
    calls.add('startService');
    startCalls++;
    if (failStart) throw StateError('start failed');
    running = true;
    lastTitle = notificationTitle;
    lastText = notificationText;
  }

  @override
  Future<void> updateService({
    ForegroundTaskOptions? foregroundTaskOptions,
    String? notificationTitle,
    String? notificationText,
    NotificationIcon? notificationIcon,
    List<NotificationButton>? notificationButtons,
    String? notificationInitialRoute,
    Function? callback,
  }) async {
    calls.add('updateService');
    updateCalls++;
    lastTitle = notificationTitle;
    lastText = notificationText;
  }

  @override
  Future<void> stopService() async {
    calls.add('stopService');
    stopCalls++;
    running = false;
  }

  @override
  Future<bool> get isRunningService async => running;

  @override
  Future<NotificationPermission> requestNotificationPermission() async {
    requestedPermission = true;
    return NotificationPermission.granted;
  }

  @override
  Future<bool> get isIgnoringBatteryOptimizations async =>
      ignoringBatteryOptimizations;

  @override
  Future<bool> openIgnoreBatteryOptimizationSettings() async {
    openedBatterySettings = true;
    return true;
  }

  @override
  void setTaskHandler(TaskHandler handler) {
    taskHandler = handler;
  }

  @override
  void launchApp([String? route]) {
    launchedRoute = route;
  }
}

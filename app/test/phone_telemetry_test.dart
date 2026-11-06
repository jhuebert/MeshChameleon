import 'dart:async';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/services/build_info.dart';
import 'package:meshchameleon/services/device_link_phase.dart';
import 'package:meshchameleon/services/diagnostics_snapshot.dart';
import 'package:meshchameleon/services/foreground_controller.dart';
import 'package:meshchameleon/services/foreground_service.dart';
import 'package:meshchameleon/services/phone_battery_service.dart';
import 'package:meshchameleon/services/proxy_status.dart';
import 'package:meshchameleon/services/phone_location_service.dart';
import 'package:meshchameleon/services/phone_sensor_settings.dart';

class _ManualTimer implements Timer {
  _ManualTimer(this.callback);

  final void Function() callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    callback();
  }
}

class _TimerHarness {
  final List<_ManualTimer> timers = [];
  Duration? lastDelay;

  Timer create(Duration delay, void Function() action) {
    lastDelay = delay;
    final timer = _ManualTimer(action);
    timers.add(timer);
    return timer;
  }

  _ManualTimer? get active {
    for (final timer in timers.reversed) {
      if (timer.isActive) return timer;
    }
    return null;
  }
}

class _GpsProvider extends VirtualSensorSettingsProvider {
  const _GpsProvider();

  @override
  Map<String, String> get initialSettings =>
      const {'gps': '1', 'gps_interval': '900'};

  @override
  bool supports(String key) => key == 'gps' || key == 'gps_interval';

  @override
  String? normalize(String key, String value) => value;
}

class _ThrowOnFixNode extends MeshNode {
  _ThrowOnFixNode({required super.identity, required super.link});

  @override
  Future<void> applyLocationFix(VirtualLocationFix fix) async {
    throw StateError('apply failed');
  }
}

Position _position({
  double latitude = 51.5,
  double longitude = -0.12,
  double altitude = 20,
  DateTime? timestamp,
}) =>
    Position(
      latitude: latitude,
      longitude: longitude,
      altitude: altitude,
      altitudeAccuracy: 1,
      accuracy: 5,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
      timestamp: timestamp ?? DateTime.utc(2026, 1, 1),
    );

Future<MeshNode> _node(int seed) async {
  final identity = await LocalIdentity.fromSeed(Uint8List(32)..[0] = seed);
  return MeshNode(
    identity: identity,
    link: FakeDeviceLink(),
    sensorSettings: const _GpsProvider(),
  );
}

class _FakeForegroundService extends ForegroundService {
  int starts = 0;
  bool includeLocation = false;
  bool fail = false;

  @override
  bool get isSupported => true;

  @override
  bool get includesLocation => includeLocation;

  @override
  Future<void> start({
    required String title,
    required String text,
    bool includeLocation = false,
  }) async {
    if (fail) throw StateError('service unavailable');
    starts++;
    this.includeLocation = includeLocation;
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('PhoneBatteryService', () {
    test('returns the clamped platform value and caches it', () async {
      final service = PhoneBatteryService(readLevel: () async => 42);
      expect(await service.read(), 42);
      expect(service.lastValue, 42);
      expect(service.lastReadAt, isNotNull);
      expect(service.lastError, isNull);
    });

    test('clamps values outside 0-100', () async {
      expect(
        await PhoneBatteryService(readLevel: () async => 140).read(),
        100,
      );
      expect(
        await PhoneBatteryService(readLevel: () async => -2).read(),
        0,
      );
    });

    test('platform failures return null and keep the last value', () async {
      var fail = false;
      final service = PhoneBatteryService(readLevel: () async {
        if (fail) throw StateError('no battery');
        return 55;
      });
      expect(await service.read(), 55);
      fail = true;
      expect(await service.read(), isNull);
      expect(service.lastValue, 55);
      expect(service.lastError, contains('no battery'));
    });
  });

  group('PhoneSensorSettingsProvider', () {
    test('supports and normalizes gps and gps_interval', () {
      final provider = PhoneSensorSettingsProvider(
        identityId: 'id',
        onChanged: (_, __) {},
      );
      expect(provider.initialSettings, {'gps': '0', 'gps_interval': '900'});
      expect(provider.supports('gps'), isTrue);
      expect(provider.supports('gps_interval'), isTrue);
      expect(provider.supports('other'), isFalse);

      expect(provider.normalize('gps', ' 1 '), '1');
      expect(provider.normalize('gps', '0'), '0');
      expect(provider.normalize('gps', 'true'), isNull);
      expect(provider.normalize('gps', '2'), isNull);

      expect(provider.normalize('gps_interval', '0'), '0');
      expect(provider.normalize('gps_interval', '900'), '900');
      expect(provider.normalize('gps_interval', '99999'), '86400');
      expect(provider.normalize('gps_interval', '-5'), '0');
      expect(provider.normalize('gps_interval', 'soon'), isNull);
    });

    test('forwards a copy of the settings with the identity id', () {
      final calls = <(String, Map<String, String>)>[];
      final provider = PhoneSensorSettingsProvider(
        identityId: 'alpha',
        onChanged: (id, settings) => calls.add((id, settings)),
      );
      final settings = {'gps': '1', 'gps_interval': '60'};
      provider.onSettingsChanged(settings);
      settings['gps'] = '0';
      expect(calls.single.$1, 'alpha');
      expect(calls.single.$2, {'gps': '1', 'gps_interval': '60'});
    });
  });

  group('PhoneLocationService', () {
    late _TimerHarness timers;
    late DateTime now;
    late PhoneLocationService service;
    late int checks;
    late int requests;
    late int settingsOpened;
    late LocationPermission permission;
    late Position? lastKnown;
    late Position? current;
    late bool currentFails;

    setUp(() {
      timers = _TimerHarness();
      now = DateTime.utc(2026, 1, 1, 12);
      checks = 0;
      requests = 0;
      settingsOpened = 0;
      permission = LocationPermission.always;
      lastKnown = null;
      current = _position(timestamp: now);
      currentFails = false;
      service = PhoneLocationService(
        checkPermission: () async {
          checks++;
          return permission;
        },
        requestPermission: () async {
          requests++;
          return permission;
        },
        lastKnownPosition: () async => lastKnown,
        currentPosition: () async {
          if (currentFails) throw StateError('gps timeout');
          return current!;
        },
        openSettings: () async {
          settingsOpened++;
          return true;
        },
        timerFactory: timers.create,
        now: () => now,
      );
    });

    tearDown(() => service.dispose());

    test('does nothing without gps demand', () async {
      final node = await _node(1);
      service.bindNode('a', node);
      service.updateSettings('a', {'gps': '0', 'gps_interval': '60'});
      await service.refreshPermission();
      expect(timers.timers, isEmpty);
      expect(service.hasDemand, isFalse);
      expect(service.effectiveIntervalSeconds, isNull);
    });

    test('does not schedule without location permission', () async {
      permission = LocationPermission.denied;
      final node = await _node(1);
      service.bindNode('a', node);
      service.updateSettings('a', {'gps': '1', 'gps_interval': '60'});
      await service.refreshPermission();
      expect(service.permissionGranted, isFalse);
      expect(timers.timers, isEmpty);
      expect(service.permissionLabel, 'Denied');
      expect(checks, greaterThan(0));
    });

    test('uses one timer and samples immediately for all identities', () async {
      final first = await _node(1);
      final second = await _node(2);
      service.bindNode('a', first);
      service.bindNode('b', second);
      service.updateSettings('a', {'gps': '1', 'gps_interval': '900'});
      service.updateSettings('b', {'gps': '1', 'gps_interval': '60'});
      await service.refreshPermission();

      expect(timers.timers, hasLength(1));
      expect(timers.lastDelay, Duration.zero);
      expect(service.effectiveIntervalSeconds, 60);

      timers.active!.fire();
      await _settle();
      expect(first.locationFix?.latitude, 51.5);
      expect(second.locationFix?.latitude, 51.5);
      expect(timers.lastDelay, const Duration(seconds: 60));
      expect(service.lastFixAt, now);
    });

    test('prefers a fresh last-known position over a new sample', () async {
      var currentReads = 0;
      service = PhoneLocationService(
        checkPermission: () async => LocationPermission.always,
        lastKnownPosition: () async =>
            _position(latitude: 1, longitude: 2, timestamp: now),
        currentPosition: () async {
          currentReads++;
          return _position();
        },
        timerFactory: timers.create,
        now: () => now,
      );
      final node = await _node(1);
      service.bindNode('a', node);
      service.updateSettings('a', {'gps': '1'});
      await service.refreshPermission();
      timers.active!.fire();
      await _settle();
      expect(currentReads, 0);
      expect(node.locationFix?.latitude, 1);
    });

    test('a failed sample keeps the previous fix and schedules again',
        () async {
      final node = await _node(1);
      service.bindNode('a', node);
      service.updateSettings('a', {'gps': '1', 'gps_interval': '60'});
      await service.refreshPermission();
      timers.active!.fire();
      await _settle();
      expect(node.locationFix, isNotNull);
      expect(service.lastError, isNull);

      currentFails = true;
      now = now.add(const Duration(seconds: 60));
      timers.active!.fire();
      await _settle();
      expect(node.locationFix, isNotNull);
      expect(service.lastError, contains('gps timeout'));
      expect(timers.active, isNotNull);
    });

    test('an interval change cancels and reschedules', () async {
      final node = await _node(1);
      service.bindNode('a', node);
      service.updateSettings('a', {'gps': '1', 'gps_interval': '900'});
      await service.refreshPermission();
      timers.active!.fire();
      await _settle();
      expect(timers.lastDelay, const Duration(seconds: 900));

      service.updateSettings('a', {'gps': '1', 'gps_interval': '30'});
      expect(timers.lastDelay, const Duration(seconds: 30));
      expect(timers.timers.where((t) => t.isActive), hasLength(1));
    });

    test('applies fixes only to identities with gps enabled', () async {
      final enabled = await _node(1);
      final disabled = await _node(2);
      service.bindNode('a', enabled);
      service.bindNode('b', disabled);
      service.updateSettings('a', {'gps': '1'});
      service.updateSettings('b', {'gps': '0'});
      await service.refreshPermission();
      timers.active!.fire();
      await _settle();
      expect(enabled.locationFix, isNotNull);
      expect(disabled.locationFix, isNull);
    });

    test('a per-node apply failure does not stop other identities', () async {
      final identity = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 9);
      final failing = _ThrowOnFixNode(
        identity: identity,
        link: FakeDeviceLink(),
      );
      final healthy = await _node(3);
      service.bindNode('a', failing);
      service.bindNode('b', healthy);
      service.updateSettings('a', {'gps': '1'});
      service.updateSettings('b', {'gps': '1'});
      await service.refreshPermission();
      timers.active!.fire();
      await _settle();
      expect(healthy.locationFix, isNotNull);
    });

    test('removing demand stops the timer', () async {
      final node = await _node(1);
      service.bindNode('a', node);
      service.updateSettings('a', {'gps': '1'});
      await service.refreshPermission();
      expect(timers.active, isNotNull);

      service.updateSettings('a', {'gps': '0'});
      expect(timers.active, isNull);
      service.unbindNode('a');
      expect(service.hasDemand, isFalse);
    });

    test('settings before bind are reconciled on bind', () async {
      service.updateSettings('a', {'gps': '1'});
      await service.refreshPermission();
      expect(timers.timers, isEmpty);
      final node = await _node(1);
      service.bindNode('a', node);
      expect(timers.timers, isNotEmpty);
    });

    test('requests permission and opens system settings', () async {
      permission = LocationPermission.whileInUse;
      expect(await service.requestForegroundPermission(), isTrue);
      expect(requests, 1);
      expect(await service.openLocationSettings(), isTrue);
      expect(settingsOpened, 1);
    });

    test('stop clears demand and cancels the timer', () async {
      final node = await _node(1);
      service.bindNode('a', node);
      service.updateSettings('a', {'gps': '1'});
      await service.refreshPermission();
      expect(timers.active, isNotNull);
      service.stop();
      expect(timers.active, isNull);
      expect(service.hasDemand, isFalse);
    });
  });

  test('foreground controller forwards the location service type', () async {
    final service = _FakeForegroundService();
    final controller = ForegroundController(
      service: service,
      identityCount: () => 1,
      activeName: () => 'One',
      devicePhase: () => DeviceLinkPhase.connected,
      deviceConnected: () => true,
      proxyStatus: () => ProxyStatus.running,
      port: () => 5000,
      log: (_) {},
      includeLocation: () => true,
    );
    await controller.start();
    expect(service.starts, 1);
    expect(service.includeLocation, isTrue);
    expect(controller.includesLocation, isTrue);

    await controller.refreshServiceTypes();
    expect(service.starts, 2);

    service.fail = true;
    await controller.refreshServiceTypes();
  });

  test('foreground controller defaults to no location type', () async {
    final service = _FakeForegroundService();
    final controller = ForegroundController(
      service: service,
      identityCount: () => 0,
      activeName: () => null,
      devicePhase: () => DeviceLinkPhase.idle,
      deviceConnected: () => false,
      proxyStatus: () => ProxyStatus.stopped,
      port: () => 5000,
      log: (_) {},
    );
    await controller.start();
    expect(service.includeLocation, isFalse);
    await controller.refreshServiceTypes();
    expect(service.starts, 2);
  });

  test('diagnostics report includes phone state without coordinates', () {
    final snapshot = DiagnosticsSnapshot(
      buildInfo: BuildInfo.fallback(),
      generatedAt: DateTime.utc(2026, 1, 1),
      appUptime: const Duration(minutes: 1),
      proxyRunning: false,
      proxyPort: 5000,
      deviceConnected: false,
      deviceLabel: null,
      deviceInfo: null,
      deviceSessionDuration: null,
      reconnectAttempts: 0,
      reconnectSuccesses: 0,
      foregroundServiceRunning: false,
      batteryOptimizationsIgnored: null,
      autoResume: false,
      identityDatabaseError: null,
      companion: CompanionMetrics(),
      link: LinkMetrics(),
      identities: const [],
      recentLogs: const [],
      phoneBatteryPercent: 42,
      phoneGpsRequested: true,
      phoneLocationPermission: 'Allow all the time',
      phoneGpsIntervalSeconds: 60,
      phoneGpsLastFixAge: const Duration(seconds: 5),
      foregroundIncludesLocation: true,
    );
    final report = snapshot.toReport();
    expect(report, contains('Phone battery: 42%'));
    expect(report, contains('Phone GPS: enabled'));
    expect(report, contains('Phone GPS interval: 60s'));
    expect(report, contains('location'));
    expect(report, isNot(contains('51.5')));
  });
}

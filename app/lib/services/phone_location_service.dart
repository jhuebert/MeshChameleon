import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:mesh_node/mesh_node.dart';

typedef PhonePermissionCheck = Future<LocationPermission> Function();
typedef PhoneLastKnownPosition = Future<Position?> Function();
typedef PhoneCurrentPosition = Future<Position> Function();
typedef PhoneOpenSettings = Future<bool> Function();
typedef PhoneTimerFactory = Timer Function(
    Duration delay, void Function() action);

/// One demand-driven location timer shared by every live identity.
///
/// The service takes one-shot fixes only: never a continuous position stream.
/// All identities with `gps=1` receive each accepted fix; the shortest
/// `gps_interval` among them controls the cadence. No coordinates are logged.
class PhoneLocationService {
  PhoneLocationService({
    PhonePermissionCheck? checkPermission,
    PhonePermissionCheck? requestPermission,
    PhoneLastKnownPosition? lastKnownPosition,
    PhoneCurrentPosition? currentPosition,
    PhoneOpenSettings? openSettings,
    PhoneTimerFactory? timerFactory,
    DateTime Function()? now,
  })  : _checkPermission = checkPermission ?? Geolocator.checkPermission,
        _requestPermission = requestPermission ?? Geolocator.requestPermission,
        _lastKnownPosition =
            lastKnownPosition ?? Geolocator.getLastKnownPosition,
        _currentPosition = currentPosition ?? _defaultCurrentPosition,
        _openSettings = openSettings ?? Geolocator.openAppSettings,
        _timerFactory =
            timerFactory ?? ((delay, action) => Timer(delay, action)),
        _now = now ?? DateTime.now;

  final PhonePermissionCheck _checkPermission;
  final PhonePermissionCheck _requestPermission;
  final PhoneLastKnownPosition _lastKnownPosition;
  final PhoneCurrentPosition _currentPosition;
  final PhoneOpenSettings _openSettings;
  final PhoneTimerFactory _timerFactory;
  final DateTime Function() _now;

  final Map<String, MeshNode> _nodes = {};
  final Map<String, Map<String, String>> _settings = {};

  Timer? _timer;
  Duration? _scheduledInterval;
  bool _sampling = false;
  bool _checkingPermission = false;
  bool _disposed = false;
  LocationPermission? _permission;
  VirtualLocationFix? _lastFix;
  DateTime? _lastAttemptAt;
  DateTime? _lastSuccessAt;
  String? _lastError;

  static const int defaultIntervalSeconds = 900;

  static Future<Position> _defaultCurrentPosition() =>
      Geolocator.getCurrentPosition(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: const Duration(seconds: 30),
          useMSLAltitude: true,
        ),
      );

  /// Whether any bound identity currently has `gps=1`.
  bool get hasDemand => _nodes.keys.any(
        (id) => _settings[id]?['gps'] == '1',
      );

  bool get gpsRequested =>
      _settings.values.any((settings) => settings['gps'] == '1');

  bool get permissionGranted =>
      _permission == LocationPermission.always ||
      _permission == LocationPermission.whileInUse;

  LocationPermission? get permission => _permission;

  String get permissionLabel => switch (_permission) {
        null => 'Checking…',
        LocationPermission.always => 'Allow all the time',
        LocationPermission.whileInUse => 'While using the app',
        LocationPermission.denied => 'Denied',
        LocationPermission.deniedForever => 'Denied forever',
        LocationPermission.unableToDetermine => 'Unavailable',
      };

  /// Effective cadence in seconds, or null when nothing requests GPS.
  int? get effectiveIntervalSeconds {
    if (!hasDemand) return null;
    return _effectiveInterval.inSeconds;
  }

  DateTime? get lastFixAt => _lastFix?.capturedAt;
  DateTime? get lastAttemptAt => _lastAttemptAt;
  DateTime? get lastSuccessAt => _lastSuccessAt;
  String? get lastError => _lastError;

  Duration? get lastFixAge {
    final fix = _lastFix;
    if (fix == null) return null;
    final age = _now().difference(fix.capturedAt);
    return age.isNegative ? Duration.zero : age;
  }

  Duration get _effectiveInterval {
    var shortest = defaultIntervalSeconds;
    var found = false;
    for (final entry in _settings.entries) {
      if (!_nodes.containsKey(entry.key)) continue;
      if (entry.value['gps'] != '1') continue;
      final parsed = int.tryParse(entry.value['gps_interval'] ?? '') ??
          defaultIntervalSeconds;
      final seconds = parsed.clamp(0, 86400);
      final effective = seconds > 0 ? seconds : 1;
      if (!found || effective < shortest) {
        shortest = effective;
        found = true;
      }
    }
    return Duration(seconds: found ? shortest : 1);
  }

  /// Whether [identityId] currently has a bound live node.
  bool isBound(String identityId) => _nodes.containsKey(identityId);

  void bindNode(String identityId, MeshNode node) {
    _nodes[identityId] = node;
    _reconcile();
  }

  void unbindNode(String identityId) {
    _nodes.remove(identityId);
    _reconcile();
  }

  /// Store settings even before the node is bound; reconcile on bind.
  void updateSettings(String identityId, Map<String, String> settings) {
    _settings[identityId] = Map<String, String>.of(settings);
    _reconcile();
  }

  /// Refresh the cached permission and start/stop sampling as needed.
  Future<void> refreshPermission() async {
    if (_disposed || _checkingPermission) return;
    _checkingPermission = true;
    try {
      _permission = await _checkPermission();
    } catch (_) {
      _permission = LocationPermission.unableToDetermine;
    } finally {
      _checkingPermission = false;
    }
    _reconcile();
  }

  /// Prompt for location access. Denial is not fatal: demand stays persisted.
  Future<bool> requestForegroundPermission() async {
    if (_disposed) return false;
    try {
      _permission = await _requestPermission();
      _lastError = null;
    } catch (e) {
      _lastError = '$e';
    }
    _reconcile();
    return permissionGranted;
  }

  Future<bool> openLocationSettings() async {
    if (_disposed) return false;
    try {
      return await _openSettings();
    } catch (e) {
      _lastError = '$e';
      return false;
    }
  }

  /// Stop sampling and drop demand without disposing the service.
  void stop() {
    _cancelTimer();
    _nodes.clear();
  }

  void dispose() {
    _disposed = true;
    _cancelTimer();
    _nodes.clear();
  }

  void _reconcile() {
    if (_disposed) return;
    if (!hasDemand) {
      _cancelTimer();
      return;
    }
    if (_permission == null) {
      unawaited(refreshPermission());
      return;
    }
    if (!permissionGranted) {
      _cancelTimer();
      return;
    }
    final interval = _effectiveInterval;
    if (_timer == null) {
      _schedule(interval, immediate: _staleSuccess(interval));
    } else if (interval != _scheduledInterval) {
      _cancelTimer();
      _schedule(interval, immediate: _staleSuccess(interval));
    }
  }

  /// True when there is no successful fix, or the last one is at least one
  /// interval old. Used to take an immediate sample after resume/permission
  /// changes without sampling more often than the configured cadence.
  bool _staleSuccess(Duration interval) {
    final last = _lastSuccessAt;
    if (last == null) return true;
    final age = _now().difference(last);
    return age.isNegative || age >= interval;
  }

  void _schedule(Duration interval, {required bool immediate}) {
    _scheduledInterval = interval;
    _timer = _timerFactory(
      immediate ? Duration.zero : interval,
      () => unawaited(_tick()),
    );
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
    _scheduledInterval = null;
  }

  Future<void> _tick() async {
    _timer = null;
    if (_disposed || !hasDemand || _sampling) return;
    if (!permissionGranted) {
      _cancelTimer();
      return;
    }
    _sampling = true;
    _lastAttemptAt = _now();
    try {
      final last = await _lastKnownPosition();
      final interval = _effectiveInterval;
      if (last != null && _isValid(last) && _ageOf(last) <= interval) {
        _applyFix(last);
      } else {
        _applyFix(await _currentPosition());
      }
      _lastSuccessAt = _now();
      _lastError = null;
    } catch (e) {
      _lastError = '$e';
    } finally {
      _sampling = false;
      if (!_disposed && hasDemand && permissionGranted) {
        _schedule(_effectiveInterval, immediate: false);
      }
    }
  }

  Duration _ageOf(Position position) {
    final age = _now().difference(position.timestamp);
    return age.isNegative ? Duration.zero : age;
  }

  bool _isValid(Position position) =>
      position.latitude.isFinite &&
      position.longitude.isFinite &&
      position.latitude >= -90 &&
      position.latitude <= 90 &&
      position.longitude >= -180 &&
      position.longitude <= 180;

  void _applyFix(Position position) {
    if (!_isValid(position)) {
      throw StateError('invalid location fix');
    }
    final fix = VirtualLocationFix(
      latitude: position.latitude,
      longitude: position.longitude,
      altitudeMeters: position.altitude.isFinite ? position.altitude : null,
      capturedAt: position.timestamp,
    );
    _lastFix = fix;
    for (final entry in _nodes.entries) {
      if (_settings[entry.key]?['gps'] != '1') continue;
      unawaited(
        entry.value.applyLocationFix(fix).catchError((Object _) {}),
      );
    }
  }
}

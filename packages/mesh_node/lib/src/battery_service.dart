import 'dart:async';

import 'scheduler.dart';
import 'virtual_clock.dart';

/// Owns the physical battery-voltage sample used by the virtual companion.
///
/// One successful sample is shared by every consumer. Reads are coalesced while
/// in flight, reused for [freshFor], and refreshed every [periodicInterval]
/// while [start]ed. Physical storage fields are never retained here; callers
/// report only the virtual storage partition alongside this voltage.
class BatteryService {
  BatteryService({
    required Future<int?> Function() readVoltage,
    required VirtualClock clock,
    required MeshScheduler scheduler,
    this.periodicInterval = const Duration(seconds: 60),
    this.freshFor = const Duration(seconds: 10),
  })  : _readVoltage = readVoltage,
        _clock = clock,
        _scheduler = scheduler;

  final Future<int?> Function() _readVoltage;
  final VirtualClock _clock;
  final MeshScheduler _scheduler;
  final Duration periodicInterval;
  final Duration freshFor;

  int _millivolts = 0;
  int? _lastSuccessAtMs;
  String? _lastError;
  bool _running = false;
  int _generation = 0;
  Future<int>? _inFlight;
  CancelScheduled? _periodicCancel;

  /// Last good physical voltage, or 0 before any successful sample.
  int get millivolts => _millivolts;

  bool get hasSample => _lastSuccessAtMs != null;

  /// Monotonic age of the last successful sample, or null if there is none.
  int? get sampleAgeMilliseconds {
    final at = _lastSuccessAtMs;
    if (at == null) return null;
    final age = _clock.monotonicMilliseconds - at;
    return age < 0 ? 0 : age;
  }

  int? get sampleAgeSeconds {
    final ms = sampleAgeMilliseconds;
    return ms == null ? null : ms ~/ 1000;
  }

  /// True when no sample exists or the last success is at least [freshFor] old.
  bool get stale {
    final age = sampleAgeMilliseconds;
    return age == null || age >= freshFor.inMilliseconds;
  }

  String? get lastError => _lastError;

  /// Human-readable staleness/failure detail for app diagnostics.
  String? get diagnostic {
    final age = sampleAgeSeconds;
    if (_lastError != null) {
      return age == null
          ? 'battery read failed: $_lastError; no successful sample'
          : 'battery read failed: $_lastError; last sample ${age}s old';
    }
    if (age == null) return null;
    if (stale) return 'battery sample stale: ${age}s old';
    return null;
  }

  /// Start first refresh and the 60s periodic refresh.
  ///
  /// Repeated calls (for example after a device reconnect) refresh once but do
  /// not create a second timer.
  void start() {
    if (!_running) {
      _running = true;
      _generation++;
    }
    _ensurePeriodic();
    unawaited(refresh(force: true));
  }

  /// Stop periodic work. Any read still in flight belongs to the old
  /// generation and cannot publish its result after this point.
  void stop() {
    _running = false;
    _generation++;
    _periodicCancel?.call();
    _periodicCancel = null;
    _inFlight = null;
  }

  void _ensurePeriodic() {
    if (!_running || _periodicCancel != null) return;
    final generation = _generation;
    _periodicCancel = _scheduler.schedule(periodicInterval, () {
      _periodicCancel = null;
      if (!_running || generation != _generation) return;
      _ensurePeriodic();
      unawaited(refresh(force: true));
    });
  }

  /// Return a fresh voltage sample, reusing a successful sample younger than
  /// [freshFor] unless [force] is set. Concurrent callers share one read.
  Future<int> refresh({bool force = false}) {
    final pending = _inFlight;
    if (pending != null) return pending;
    final age = sampleAgeMilliseconds;
    if (!force && age != null && age < freshFor.inMilliseconds) {
      return Future<int>.value(_millivolts);
    }

    final generation = _generation;
    late Future<int> future;
    future = _readAndApply(generation).whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
    _inFlight = future;
    return future;
  }

  Future<int> _readAndApply(int generation) async {
    try {
      final millivolts = await _readVoltage();
      if (generation != _generation) return _millivolts;
      if (millivolts == null) {
        _lastError = 'no reading returned';
        return _millivolts;
      }
      _millivolts = millivolts.clamp(0, 0xFFFF);
      _lastSuccessAtMs = _clock.monotonicMilliseconds;
      _lastError = null;
      return _millivolts;
    } catch (e) {
      if (generation == _generation) _lastError = '$e';
      return _millivolts;
    }
  }
}

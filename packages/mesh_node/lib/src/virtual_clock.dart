/// Injected wall/monotonic clock for the virtual companion.
///
/// Wall time is the host clock plus a runtime virtual-seconds offset. The
/// offset is intentionally not persisted: after a restart virtual time begins
/// from the host clock again. Timezone changes never alter epoch seconds.
///
/// Monotonic time is used for timers, uptime, retry ages, and dedup TTLs, so a
/// virtual wall-clock jump cannot expire them.
class VirtualClock {
  VirtualClock({
    DateTime Function()? hostWallClock,
    Duration Function()? monotonicClock,
  })  : _hostWallClock = hostWallClock ?? DateTime.now,
        _monotonicClock = monotonicClock ?? _defaultMonotonic;

  static final Stopwatch _stopwatch = Stopwatch()..start();

  static Duration _defaultMonotonic() => _stopwatch.elapsed;

  final DateTime Function() _hostWallClock;
  final Duration Function() _monotonicClock;

  int _offsetSeconds = 0;

  /// Virtual wall time in whole epoch seconds.
  int get wallSeconds =>
      _hostWallClock().millisecondsSinceEpoch ~/ 1000 + _offsetSeconds;

  /// Virtual wall time truncated to whole seconds.
  DateTime get wallTime =>
      DateTime.fromMillisecondsSinceEpoch(wallSeconds * 1000);

  /// Monotonic elapsed milliseconds since this clock was created.
  int get monotonicMilliseconds => _monotonicClock().inMilliseconds;

  /// Monotonic elapsed whole seconds.
  int get monotonicSeconds => monotonicMilliseconds ~/ 1000;

  /// Move virtual wall time to [seconds] when it is not in the past.
  ///
  /// Returns `false` without changing the clock when [seconds] is behind the
  /// current virtual time. Setting equal is allowed.
  bool setWallSeconds(int seconds) {
    final current = wallSeconds;
    if (seconds < current) return false;
    _offsetSeconds += seconds - current;
    return true;
  }
}

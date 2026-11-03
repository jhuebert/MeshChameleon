import 'dart:async';

/// Deterministic timer source for server lifecycle tests.
class FakeScheduler {
  FakeScheduler({DateTime? start}) : _now = start ?? DateTime.utc(2026);

  DateTime _now;
  final List<_FakeTimer> _timers = [];

  DateTime get now => _now;

  Timer create(Duration duration, void Function() callback) =>
      _schedule(duration, null, (_) => callback());

  Timer createPeriodic(Duration duration, void Function(Timer) callback) =>
      _schedule(duration, duration, callback);

  Timer _schedule(
    Duration duration,
    Duration? period,
    void Function(Timer) callback,
  ) {
    final timer = _FakeTimer(
      due: _now.add(duration),
      period: period,
      callback: callback,
    );
    _timers.add(timer);
    return timer;
  }

  /// Advance time, firing every due timer in due order.
  void elapse(Duration duration) {
    final target = _now.add(duration);
    while (true) {
      _FakeTimer? next;
      for (final timer in _timers) {
        if (!timer.isActive || timer.due.isAfter(target)) continue;
        if (next == null || timer.due.isBefore(next.due)) next = timer;
      }
      if (next == null) break;
      _now = next.due;
      next._tick++;
      if (next.period == null) {
        next._active = false;
      } else {
        next._due = next._due.add(next.period!);
      }
      next._callback(next);
    }
    _now = target;
  }
}

class _FakeTimer implements Timer {
  _FakeTimer({
    required DateTime due,
    required this.period,
    required void Function(Timer) callback,
  })  : _due = due,
        _callback = callback;

  DateTime _due;
  final Duration? period;
  final void Function(Timer) _callback;
  bool _active = true;
  int _tick = 0;

  DateTime get due => _due;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  @override
  void cancel() => _active = false;
}

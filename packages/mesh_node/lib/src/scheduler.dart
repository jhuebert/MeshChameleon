import 'dart:async';

/// Cancels a scheduled callback.
typedef CancelScheduled = void Function();

/// Injectable scheduler for virtual endpoint timers (ACK delays).
abstract class MeshScheduler {
  CancelScheduled schedule(Duration delay, void Function() action);
}

/// Default scheduler backed by Dart event-loop timers.
class TimerMeshScheduler implements MeshScheduler {
  const TimerMeshScheduler();

  @override
  CancelScheduled schedule(Duration delay, void Function() action) {
    final timer = Timer(delay, action);
    return timer.cancel;
  }
}

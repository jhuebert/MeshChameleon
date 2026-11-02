import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

import 'scheduler.dart';
import 'virtual_clock.dart';

/// One outbound message awaiting its ACK.
class PendingAck {
  PendingAck(
    this.crc,
    this.contactPubkey,
    this.timer,
    this.sentAtMonotonicMillis,
  );

  final int crc;
  final Uint8List contactPubkey;
  final Timer timer;
  final int sentAtMonotonicMillis;
}

/// Endpoint ACK scheduling and pending-send confirmation.
///
/// Scheduled work is scoped to the identity generation that created it so an
/// identity switch or reset cannot deliver a stale ACK/reply.
class AckTracker {
  AckTracker({
    required this.scheduler,
    required this.clock,
    required this.generation,
    required this.isCurrent,
    required this.onConfirmed,
  });

  final MeshScheduler scheduler;
  final VirtualClock clock;
  final int Function() generation;
  final bool Function(int generation) isCurrent;
  final void Function(int crc, int tripTimeMs) onConfirmed;

  final List<PendingAck> _pending = [];
  final List<CancelScheduled> _scheduled = [];

  CancelScheduled schedule(Duration delay, void Function() action) {
    final createdGeneration = generation();
    CancelScheduled? cancel;
    var ran = false;
    cancel = scheduler.schedule(delay, () {
      ran = true;
      if (cancel != null) _scheduled.remove(cancel);
      if (!isCurrent(createdGeneration)) return;
      action();
    });
    if (ran) {
      // A synchronous scheduler already executed the action; there is nothing
      // to track or cancel.
      return () {};
    }
    _scheduled.add(cancel);
    return cancel;
  }

  void cancelScheduled() {
    for (final cancel in _scheduled) {
      cancel();
    }
    _scheduled.clear();
  }

  PendingAck register(int crc, Uint8List contactPubkey, Duration timeout) {
    final timer = Timer(timeout, () {
      _pending.removeWhere((ack) => ack.crc == crc);
    });
    final pending = PendingAck(
      crc,
      contactPubkey,
      timer,
      clock.monotonicMilliseconds,
    );
    _pending.add(pending);
    return pending;
  }

  void cancel(PendingAck pending) {
    pending.timer.cancel();
    _pending.remove(pending);
  }

  /// Confirm a matching pending send. Returns true when one was found.
  bool confirm(int crc) {
    final index = _pending.indexWhere((ack) => ack.crc == (crc & 0xFFFFFFFF));
    if (index < 0) return false;
    final pending = _pending.removeAt(index);
    pending.timer.cancel();
    final tripTime =
        (clock.monotonicMilliseconds - pending.sentAtMonotonicMillis)
            .clamp(0, 0xFFFFFFFF);
    onConfirmed(crc & 0xFFFFFFFF, tripTime);
    return true;
  }

  void removeForContact(Uint8List pubkey) {
    final hex = bytesToHex(pubkey);
    _pending.removeWhere((ack) {
      final matches = bytesToHex(ack.contactPubkey) == hex;
      if (matches) ack.timer.cancel();
      return matches;
    });
  }

  void clearPending() {
    for (final pending in _pending) {
      pending.timer.cancel();
    }
    _pending.clear();
  }
}

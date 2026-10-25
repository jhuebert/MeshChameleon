import 'dart:async';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

class _FakeJob {
  _FakeJob(this.at, this.action);
  final int at;
  final void Function() action;
  bool done = false;
  bool cancelled = false;
}

class _FakeScheduler implements MeshScheduler {
  int now = 0;
  final List<_FakeJob> jobs = [];

  int get pending => jobs.where((j) => !j.done && !j.cancelled).length;

  @override
  CancelScheduled schedule(Duration delay, void Function() action) {
    final job = _FakeJob(now + delay.inMilliseconds, action);
    jobs.add(job);
    return () => job.cancelled = true;
  }

  void advance(Duration delay) {
    now += delay.inMilliseconds;
    var ran = true;
    while (ran) {
      ran = false;
      for (final job in List<_FakeJob>.of(jobs)) {
        if (!job.done && !job.cancelled && job.at <= now) {
          job.done = true;
          job.action();
          ran = true;
        }
      }
    }
  }

  void resetJobs() {
    jobs.clear();
    now = 0;
  }
}

class _Fixture {
  _Fixture(this.node, this.link, this.scheduler, this._advance);

  final MeshNode node;
  final FakeDeviceLink link;
  final _FakeScheduler scheduler;
  final void Function(Duration) _advance;

  void advance(Duration delay) => _advance(delay);
}

Future<_Fixture> _makeFixture({
  BatteryReading? battery = const BatteryReading(
    millivolts: 4000,
    storageUsedKb: 12,
    storageTotalKb: 1024,
  ),
  int? millivolts,
}) async {
  var monotonic = Duration.zero;
  final clock = VirtualClock(monotonicClock: () => monotonic);
  final scheduler = _FakeScheduler();
  final reading = millivolts == null
      ? battery
      : BatteryReading(
          millivolts: millivolts,
          storageUsedKb: 12,
          storageTotalKb: 1024,
        );
  final link = FakeDeviceLink(batteryReading_: reading);
  await link.connect();
  final identity =
      await LocalIdentity.fromSeed(Uint8List(32)..[0] = 90);
  final node = MeshNode(
    identity: identity,
    link: link,
    clock: clock,
    scheduler: scheduler,
  );
  return _Fixture(
    node,
    link,
    scheduler,
    (delay) => monotonic += delay,
  );
}

Future<void> _flush() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  test('polls_observe_3700_then3650_after_ttl', () async {
    final f = await _makeFixture(
      battery: const BatteryReading(
        millivolts: 3700,
        storageUsedKb: 12,
        storageTotalKb: 1024,
      ),
    );
    addTearDown(f.node.stop);
    f.node.start();

    final first = await f.node.getBatteryAndStorage();
    expect(first.millivolts, 3700);
    expect(first.storageTotalKb, virtualStorageTotalKb);
    expect(first.storageUsedKb, storageKibForBytes(f.node.storageUsedBytes));
    expect(first.storageUsedKb, isNot(12),
        reason: 'physical storage is discarded');
    expect(f.link.calls, contains('battery'));

    f.link.batteryReading_ = const BatteryReading(
      millivolts: 3650,
      storageUsedKb: 777,
      storageTotalKb: 888,
    );
    final cached = await f.node.getBatteryAndStorage();
    expect(cached.millivolts, 3700, reason: 'within the 10s TTL');
    expect(f.link.batteryReads, 1);

    f.advance(const Duration(seconds: 10));
    final refreshed = await f.node.getBatteryAndStorage();
    expect(refreshed.millivolts, 3650);
    expect(refreshed.storageTotalKb, virtualStorageTotalKb);
    expect(refreshed.storageUsedKb,
        storageKibForBytes(f.node.storageUsedBytes));
    expect(refreshed.storageUsedKb, isNot(777));
    expect(f.link.batteryReads, 2);
  });

  test('within10s_reuses_sample_simultaneous_stale_calls_share_one_read',
      () async {
    final f = await _makeFixture(millivolts: 3700);
    addTearDown(f.node.stop);
    f.node.start();
    expect((await f.node.getBatteryAndStorage()).millivolts, 3700);
    expect(f.link.batteryReads, 1);

    // Still fresh: repeated consumers reuse the successful sample.
    await f.node.getBatteryAndStorage();
    await f.node.getStats(statsTypeCore);
    expect(f.link.batteryReads, 1);

    // At the TTL boundary, several consumers must share one physical read.
    f.advance(const Duration(seconds: 10));
    f.link.batteryReading_ = const BatteryReading(
      millivolts: 3800,
      storageUsedKb: 0,
      storageTotalKb: 0,
    );
    f.link.batteryAck = Completer<void>();
    final battery1 = f.node.getBatteryAndStorage();
    final battery2 = f.node.getBatteryAndStorage();
    final core = f.node.getStats(statsTypeCore);
    await _flush();
    expect(f.link.batteryReads, 2, reason: 'one coalesced read');

    f.link.batteryAck!.complete();
    f.link.batteryAck = null;
    expect((await battery1).millivolts, 3800);
    expect((await battery2).millivolts, 3800);
    expect((await core)['battery_mv'], 3800);
    expect(f.link.batteryReads, 2);
  });

  test('periodic60s_and_reconnect_refresh_once_repeated_start_no_double_timer',
      () async {
    final f = await _makeFixture(millivolts: 3700);
    addTearDown(f.node.stop);
    f.node.start();
    expect((await f.node.getBatteryAndStorage()).millivolts, 3700);
    expect(f.link.batteryReads, 1);
    expect(f.scheduler.pending, 1, reason: 'one 60s periodic timer');

    f.link.batteryReading_ = const BatteryReading(
      millivolts: 3600,
      storageUsedKb: 0,
      storageTotalKb: 0,
    );
    f.scheduler.advance(const Duration(seconds: 60));
    await _flush();
    expect(f.link.batteryReads, 2, reason: 'periodic refresh');
    expect(f.scheduler.pending, 1, reason: 'rescheduled once');

    // A device reconnect re-arms the node; it refreshes but must not duplicate
    // the periodic timer.
    f.link.batteryReading_ = const BatteryReading(
      millivolts: 3500,
      storageUsedKb: 0,
      storageTotalKb: 0,
    );
    f.node.start();
    expect((await f.node.getBatteryAndStorage()).millivolts, 3500);
    expect(f.link.batteryReads, 3);
    expect(f.scheduler.pending, 1);
    f.node.start();
    expect((await f.node.getBatteryAndStorage()).millivolts, 3500);
    expect(f.link.batteryReads, 4);
    expect(f.scheduler.pending, 1, reason: 'repeated start never adds a timer');
  });

  test('stop_cancels_timer_late_read_cannot_update_stopped_generation',
      () async {
    final f = await _makeFixture(millivolts: 3700);
    f.node.start();
    expect((await f.node.getBatteryAndStorage()).millivolts, 3700);
    expect(f.scheduler.pending, 1);

    f.advance(const Duration(seconds: 10));
    f.link.batteryReading_ = const BatteryReading(
      millivolts: 3650,
      storageUsedKb: 0,
      storageTotalKb: 0,
    );
    f.link.batteryAck = Completer<void>();
    final late = f.node.getBatteryAndStorage();
    await _flush();
    expect(f.link.batteryReads, 2);

    f.node.stop();
    expect(f.scheduler.pending, 0, reason: 'stop cancels the periodic work');
    f.link.batteryAck!.complete();
    f.link.batteryAck = null;

    final result = await late;
    expect(result.millivolts, 3700,
        reason: 'late read belongs to the stopped generation');
    expect(f.node.battery.millivolts, 3700);
    expect(f.node.battery.sampleAgeSeconds, 10);
    expect(f.link.batteryReads, 2);
  });

  test('failure_returns_last_good_or_zero_and_keeps_real_sample_age', () async {
    final f = await _makeFixture(millivolts: 3700);
    addTearDown(f.node.stop);
    f.node.start();
    expect((await f.node.getBatteryAndStorage()).millivolts, 3700);

    f.advance(const Duration(seconds: 10));
    f.link.batteryReading_ = null;
    final lastGood = await f.node.getBatteryAndStorage();
    expect(lastGood.millivolts, 3700);
    expect(f.node.battery.hasSample, isTrue);
    expect(f.node.battery.sampleAgeSeconds, 10,
        reason: 'failure must not fabricate a fresh sample timestamp');
    expect(f.node.batteryDiagnostic, contains('no reading'));
    expect(f.node.batteryStale, isTrue);

    f.advance(const Duration(seconds: 5));
    final stillLastGood = await f.node.getBatteryAndStorage();
    expect(stillLastGood.millivolts, 3700);
    expect(f.node.battery.sampleAgeSeconds, 15);
    expect(f.node.batteryDiagnostic, contains('15s old'));
    expect(f.link.batteryReads, 3);

    final empty = await _makeFixture(battery: null);
    addTearDown(empty.node.stop);
    empty.node.start();
    final zero = await empty.node.getBatteryAndStorage();
    expect(zero.millivolts, 0);
    expect(empty.node.battery.hasSample, isFalse);
    expect(empty.node.batteryStale, isTrue);
    expect(empty.node.batteryDiagnostic, contains('no successful sample'));
  });

  test('core_stats_and_self_telemetry_use_same_refreshed_voltage', () async {
    final f = await _makeFixture(millivolts: 3700);
    addTearDown(f.node.stop);
    f.node.start();
    expect((await f.node.getBatteryAndStorage()).millivolts, 3700);

    f.advance(const Duration(seconds: 10));
    f.link.batteryReading_ = const BatteryReading(
      millivolts: 3650,
      storageUsedKb: 0,
      storageTotalKb: 0,
    );
    final core = await f.node.getStats(statsTypeCore);
    final self = await f.node.getBatteryAndStorage();
    expect(core['battery_mv'], 3650);
    expect(self.millivolts, 3650);
    expect(f.link.batteryReads, 2,
        reason: 'stats and battery/self telemetry share one sample');
  });

  test('R2 battery_storage_exact_bytes_update_on_virtual_growth_and_shrink',
      () async {
    final f = await _makeFixture(
      battery: const BatteryReading(
        millivolts: 3700,
        storageUsedKb: 12,
        storageTotalKb: 1024,
      ),
    );
    addTearDown(f.node.stop);
    f.node.start();

    final initial = await f.node.getBatteryAndStorage();
    expect(initial.millivolts, 3700);
    expect(initial.storageUsedKb,
        storageKibForBytes(f.node.storageUsedBytes));
    expect(initial.storageTotalKb, virtualStorageTotalKb);
    expect(initial.storageUsedKb, isNot(12));
    expect(initial.storageTotalKb, isNot(1024));

    final keys = <Uint8List>[];
    for (var i = 0; i < 10; i++) {
      final key = Uint8List(32)
        ..[0] = 120 + i
        ..[1] = i;
      keys.add(key);
      await f.node.addUpdateContact(Contact(
        publicKey: key,
        name: 'c$i-${'x' * 12}',
        advType: advTypeChat,
      ));
    }
    final grown = await f.node.getBatteryAndStorage();
    expect(f.node.storageUsedBytes, greaterThan(0));
    expect(grown.storageUsedKb,
        storageKibForBytes(f.node.storageUsedBytes));
    expect(grown.storageUsedKb, greaterThan(initial.storageUsedKb));
    expect(grown.millivolts, 3700);
    expect(f.link.batteryReads, 1, reason: 'storage refresh is virtual only');

    for (final key in keys) {
      await f.node.removeContact(key);
    }
    final shrunk = await f.node.getBatteryAndStorage();
    expect(shrunk.storageUsedKb,
        storageKibForBytes(f.node.storageUsedBytes));
    expect(shrunk.storageUsedKb, lessThan(grown.storageUsedKb));
    expect(shrunk.storageTotalKb, virtualStorageTotalKb);
    expect(shrunk.millivolts, 3700);
    expect(f.link.batteryReads, 1,
        reason: 'no physical storage reads or battery refresh inside TTL');
  });
}

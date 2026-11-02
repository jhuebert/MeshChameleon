import 'dart:async';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

class _TestClock {
  _TestClock({int wall = 1000, Duration mono = Duration.zero})
      : _wall = wall,
        _mono = mono;

  final int _wall;
  Duration _mono;

  late final VirtualClock clock = VirtualClock(
    hostWallClock: () => DateTime.fromMillisecondsSinceEpoch(_wall * 1000),
    monotonicClock: () => _mono,
  );

  void advance(Duration duration) => _mono += duration;
}

Uint8List _key(int value) => Uint8List(32)..[0] = value;

Contact _contact(
  int value, {
  String name = '',
  int flags = 0,
  int lastmod = 0,
  int syncSince = 0,
  Uint8List? rawAdvert,
  double lat = 0,
  double lon = 0,
}) =>
    Contact(
      publicKey: _key(value),
      name: name,
      flags: flags,
      lastmod: lastmod,
      syncSince: syncSince,
      rawAdvert: rawAdvert,
      gpsLat: lat,
      gpsLon: lon,
    );

QueuedMessage _message(String text) =>
    QueuedMessage(senderKey: Uint8List(32), text: text);

class _FakeScheduler implements MeshScheduler {
  final List<({Duration delay, void Function() action})> jobs = [];

  @override
  CancelScheduled schedule(Duration delay, void Function() action) {
    final job = (delay: delay, action: action);
    jobs.add(job);
    return () => jobs.remove(job);
  }

  void runAll() {
    for (final job in List.of(jobs)) {
      jobs.remove(job);
      job.action();
    }
  }
}

class _BlockingStore implements NodeStore {
  final saveGate = Completer<void>();
  bool saveStarted = false;
  bool saveFinished = false;
  bool flushed = false;

  @override
  Future<NodeState?> load() async => null;

  @override
  Future<void> save(NodeState state) async {
    saveStarted = true;
    await saveGate.future;
    saveFinished = true;
  }

  @override
  Future<void> flush() async {
    flushed = true;
  }
}

void main() {
  group('SerialQueue', () {
    test('runs in order and continues after an error', () async {
      final queue = SerialQueue();
      final events = <String>[];

      final first = queue.run(() async {
        await Future<void>.delayed(Duration.zero);
        events.add('first');
        return 1;
      });
      final failing = queue.run<int>(() async {
        events.add('fail');
        throw StateError('boom');
      });
      final last = queue.run(() async {
        events.add('last');
        return 3;
      });

      expect(await first, 1);
      await expectLater(failing, throwsStateError);
      expect(await last, 3);
      expect(events, ['first', 'fail', 'last']);
      await queue.idle;
    });
  });

  group('FloodScope', () {
    test('override, default, unscoped, zero keys, and clear', () {
      final prefs = NodePrefs(defaultScopeKey: Uint8List(16)..[0] = 1);
      final scope = FloodScope();

      expect(scope.effective(prefs)?[0], 1);

      scope.setKey(Uint8List(16)..[0] = 2);
      expect(scope.effective(prefs)?[0], 2);

      scope.setUnscoped();
      expect(scope.effective(prefs), isNull);

      scope.setKey(Uint8List(16)..[0] = 3);
      expect(scope.effective(prefs)?[0], 3);

      scope.setKey(Uint8List(16));
      expect(scope.effective(prefs)?[0], 1,
          reason: 'a zero override falls back to the default scope');

      scope.clear();
      expect(scope.effective(prefs)?[0], 1);
    });

    test('ignores a default key with the wrong length', () {
      final prefs = NodePrefs(defaultScopeKey: Uint8List(15)..[0] = 1);
      expect(FloodScope().effective(prefs), isNull);
    });
  });

  group('PacketDeduper', () {
    test('suppresses duplicates for the TTL and then forgets them', () {
      final testClock = _TestClock();
      final deduper = PacketDeduper(clock: testClock.clock);
      final hash = Uint8List.fromList([1, 2, 3]);

      expect(deduper.isDuplicate(hash), isFalse);
      expect(deduper.isDuplicate(hash), isTrue);

      testClock.advance(const Duration(seconds: 301));
      expect(deduper.isDuplicate(hash), isFalse);
    });

    test('consumes sent-group echoes individually', () {
      final testClock = _TestClock();
      final deduper = PacketDeduper(clock: testClock.clock);
      final hash = Uint8List.fromList([9]);

      deduper.noteSentGroup(hash);
      deduper.noteSentGroup(hash);

      expect(deduper.consumeSentGroup(hash), isTrue);
      expect(deduper.consumeSentGroup(hash), isTrue);
      expect(deduper.consumeSentGroup(hash), isFalse);
    });

    test('clear resets both tables', () {
      final testClock = _TestClock();
      final deduper = PacketDeduper(clock: testClock.clock);
      final hash = Uint8List.fromList([4]);

      deduper.noteSentGroup(hash);
      deduper.isDuplicate(hash);
      deduper.clear();

      expect(deduper.isDuplicate(hash), isFalse);
      expect(deduper.consumeSentGroup(hash), isFalse);
    });
  });

  group('RequestTracker', () {
    test('generates monotonically increasing timestamps', () {
      final testClock = _TestClock(wall: 100);
      final tracker = RequestTracker(clock: testClock.clock);

      expect(tracker.nextTimestamp(), 100);
      expect(tracker.nextTimestamp(), 101);

      tracker.noteTimestamp(200);
      expect(tracker.nextTimestamp(), 201);
    });

    test('reply timestamps advance past the request and last packet', () {
      final testClock = _TestClock(wall: 100);
      final tracker = RequestTracker(clock: testClock.clock);

      expect(tracker.replyTimestamp(300), 301);
      expect(tracker.replyTimestamp(300), 302);
    });

    test('request tags avoid every in-flight tag', () {
      final testClock = _TestClock(wall: 100);
      final tracker = RequestTracker(clock: testClock.clock);
      final target = _key(1);

      tracker.registerBinary(100, target);
      tracker.registerDiscovery(101, target);
      tracker.registerTelemetry(102, target);

      expect(tracker.nextTag(), 103);
    });

    test('login/status matching and contact cleanup', () {
      final testClock = _TestClock();
      final tracker = RequestTracker(clock: testClock.clock);
      final pubkey = _key(7);
      final prefix = Uint8List.fromList(pubkey.sublist(0, 4));

      tracker.setPendingLogin(prefix);
      expect(tracker.takeLogin(prefix), isTrue);
      expect(tracker.hasPendingLogin, isFalse);

      tracker.setPendingStatus(prefix);
      expect(
        tracker.takeStatus(Uint8List.fromList(_key(99).sublist(0, 4))),
        isFalse,
        reason: 'a mismatching prefix must not consume it',
      );
      expect(tracker.hasPendingStatus, isTrue);

      tracker.registerTelemetry(1, pubkey);
      tracker.registerBinary(2, pubkey);
      tracker.registerDiscovery(3, pubkey);
      tracker.removeForContact(pubkey);

      expect(tracker.telemetryTarget(1), isNull);
      expect(tracker.binaryTarget(2), isNull);
      expect(tracker.discoveryTarget(3), isNull);
    });

    test('clear resets pending state and the tag cursor', () {
      final testClock = _TestClock(wall: 50);
      final tracker = RequestTracker(clock: testClock.clock);
      tracker.registerBinary(10, _key(1));
      tracker.setPendingLogin(Uint8List(4));

      tracker.clear();

      expect(tracker.binaryTarget(10), isNull);
      expect(tracker.hasPendingLogin, isFalse);
      expect(tracker.nextTag(), 50);
    });
  });

  group('MessageQueue', () {
    test('drops oldest entries on overflow and reports counts', () {
      final queue = MessageQueue(maxQueueSize: 2)
        ..replace([_message('one'), _message('two')]);

      final candidate = queue.candidateWith(_message('three'));

      expect(candidate.map((m) => m.text), ['two', 'three']);
      expect(queue.length, 2);
      expect(queue.directCount, 2);
      expect(queue.channelCount, 0);
    });

    test('peek and remove deliver the oldest message', () {
      final queue = MessageQueue(maxQueueSize: 2)
        ..replace([
          _message('one'),
          QueuedMessage(senderKey: Uint8List(32), isChannel: true),
        ]);

      final first = queue.peek();
      expect(first?.text, 'one');
      expect(queue.directCount, 1);
      expect(queue.channelCount, 1);

      final remaining = queue.candidateWithoutFirst();
      expect(remaining.single.isChannel, isTrue);
    });
  });

  group('ContactTable', () {
    test('upsert preserves sync cursor, advert, and GPS when requested', () {
      final table = ContactTable(clock: _TestClock().clock);
      final old = _contact(
        1,
        syncSince: 5,
        rawAdvert: Uint8List.fromList([1, 2]),
        lat: 10,
        lon: 20,
      );
      table.replacePersistent([old]);

      final result = table.upsert(
        _contact(1, name: 'new'),
        hasGps: false,
        prefs: NodePrefs(),
        maxContacts: virtualMaxContacts,
      );

      final updated = result.candidate.single;
      expect(updated.name, 'new');
      expect(updated.syncSince, 5);
      expect(updated.rawAdvert, [1, 2]);
      expect(updated.gpsLat, 10);
      expect(updated.gpsLon, 20);
    });

    test('upsert reports full or evicts the oldest non-favourite', () {
      final table = ContactTable(clock: _TestClock().clock);
      table.replacePersistent([
        _contact(1, lastmod: 10, flags: 0x01),
        _contact(2, lastmod: 5),
      ]);

      final noOverwrite = table.upsert(
        _contact(3),
        hasGps: true,
        prefs: NodePrefs(),
        maxContacts: 2,
      );
      expect(noOverwrite.full, isTrue);

      final overwrite = table.upsert(
        _contact(3),
        hasGps: true,
        prefs: NodePrefs(autoaddConfig: autoAddOverwriteOldest),
        maxContacts: 2,
      );
      expect(overwrite.full, isFalse);
      expect(overwrite.evicted?.publicKeyHex, _contact(2).publicKeyHex);
      expect(overwrite.candidate.map((c) => c.publicKeyHex),
          contains(_contact(3).publicKeyHex));
    });

    test('upsert refuses to evict favourites', () {
      final table = ContactTable(clock: _TestClock().clock);
      table.replacePersistent([_contact(1, flags: 0x01)]);

      final result = table.upsert(
        _contact(2),
        hasGps: true,
        prefs: NodePrefs(autoaddConfig: autoAddOverwriteOldest),
        maxContacts: 1,
      );
      expect(result.full, isTrue);
    });

    test('anonymous slots are bounded and replace the oldest', () {
      final testClock = _TestClock();
      final table = ContactTable(clock: testClock.clock);

      for (var i = 0; i < maxTransientContacts + 1; i++) {
        table.ensureAnon(_key(i));
        testClock.advance(const Duration(seconds: 1));
      }

      expect(table.transient, hasLength(maxTransientContacts));
      expect(table.transientIndex(_key(0)), isNull);
      expect(table.transientIndex(_key(maxTransientContacts)), isNotNull);
    });

    test('resetPath handles persistent and transient contacts', () {
      final table = ContactTable(clock: _TestClock().clock);
      final persistent = _contact(1, lastmod: 1);
      persistent
        ..outPath = Uint8List.fromList([1, 2])
        ..outPathLen = 1;
      table.replacePersistent([persistent]);
      final anon = table.ensureAnon(_key(2));
      anon
        ..outPath = Uint8List.fromList([3])
        ..outPathLen = 1;

      final candidate = table.resetPath(_key(1));
      expect(candidate?.single.outPathLen, -1);
      expect(candidate?.single.outPath, isEmpty);

      expect(table.resetPath(_key(2)), isNull);
      expect(anon.outPathLen, -1);
      expect(table.resetPath(_key(3)), isNull);
    });

    test('auto-add policy and hop limit', () {
      final table = ContactTable(clock: _TestClock().clock);
      final manual = NodePrefs(
        manualAddContacts: 1,
        autoaddConfig: autoAddChat,
        autoaddMaxHops: 2,
      );

      expect(table.shouldAutoAddType(advTypeChat, manual), isTrue);
      expect(table.shouldAutoAddType(advTypeRepeater, manual), isFalse);
      expect(table.hopAllowed(1, manual), isTrue);
      expect(table.hopAllowed(2, manual), isFalse);
    });
  });

  group('AdvertPathCache', () {
    test('records paths, bounds the cache, and looks up prefixes', () {
      final cache = AdvertPathCache();
      final packet = Packet()
        ..pathLenByte = 1
        ..path = Uint8List.fromList([1, 2]);

      for (var i = 0; i < maxAdvertPathCacheEntries + 1; i++) {
        final pubkey = _key(i);
        cache.replace(
          cache.candidate(packet, pubkey, 'n$i', i),
        );
      }

      expect(cache.length, maxAdvertPathCacheEntries);
      final newest =
          Uint8List.fromList(_key(maxAdvertPathCacheEntries).sublist(0, 7));
      expect(
          cache.paths[bytesToHex(newest)]?.name, 'n$maxAdvertPathCacheEntries');
      final oldest = Uint8List.fromList(_key(0).sublist(0, 7));
      expect(cache.paths[bytesToHex(oldest)], isNull);
    });
  });

  group('ConnectionSessions', () {
    test('tracks activity, consumes keep-alive ACKs, and stops', () async {
      final testClock = _TestClock();
      final sent = <ConnectionSession>[];
      final sessions = ConnectionSessions(
        clock: testClock.clock,
        onKeepAlive: (connection) async => sent.add(connection),
      );
      addTearDown(sessions.clear);

      final pubkey = _key(1);
      sessions.start(pubkey, 60);
      expect(sessions.contains(pubkey), isTrue);
      expect(sessions.length, 1);

      final connection = sessions.values.single;
      connection.expectedAck = 0x1234;
      expect(sessions.acceptAck(0x1234), isTrue);
      expect(connection.expectedAck, isNull);

      sessions.markActive(pubkey);
      await sessions.sendAllNow();
      expect(sent.single, same(connection));

      sessions.stop(pubkey);
      expect(sessions.contains(pubkey), isFalse);
    });

    test('ignores zero keep-alive intervals and removes by hex', () {
      final sessions = ConnectionSessions(
        clock: _TestClock().clock,
        onKeepAlive: (_) async {},
      );
      addTearDown(sessions.clear);

      sessions.start(_key(1), 0);
      expect(sessions.length, 0);

      sessions.start(_key(2), 60);
      sessions.removeByHex(bytesToHex(_key(2)));
      expect(sessions.length, 0);
    });
  });

  group('AckTracker', () {
    test('schedules only for the identity generation that created work', () {
      final scheduler = _FakeScheduler();
      var generation = 1;
      var fired = 0;
      final tracker = AckTracker(
        scheduler: scheduler,
        clock: _TestClock().clock,
        generation: () => generation,
        isCurrent: (value) => value == generation,
        onConfirmed: (_, __) {},
      );

      tracker.schedule(const Duration(milliseconds: 200), () => fired++);
      generation = 2;
      scheduler.runAll();
      expect(fired, 0);

      tracker.schedule(const Duration(milliseconds: 200), () => fired++);
      scheduler.runAll();
      expect(fired, 1);
    });

    test('confirms a pending send and reports trip time', () {
      final testClock = _TestClock(mono: const Duration(seconds: 1));
      final confirmed = <(int, int)>[];
      final tracker = AckTracker(
        scheduler: _FakeScheduler(),
        clock: testClock.clock,
        generation: () => 1,
        isCurrent: (_) => true,
        onConfirmed: (crc, trip) => confirmed.add((crc, trip)),
      );
      addTearDown(tracker.clearPending);

      final pending =
          tracker.register(0xCAFE, _key(1), const Duration(seconds: 10));
      testClock.advance(const Duration(milliseconds: 5));

      expect(tracker.confirm(0xCAFE), isTrue);
      expect(confirmed.single, (0xCAFE, 5));

      tracker.cancel(pending);
      expect(tracker.confirm(0xCAFE), isFalse);
    });

    test('drops pending sends for a removed contact', () {
      final tracker = AckTracker(
        scheduler: _FakeScheduler(),
        clock: _TestClock().clock,
        generation: () => 1,
        isCurrent: (_) => true,
        onConfirmed: (_, __) {},
      );
      addTearDown(tracker.clearPending);

      tracker.register(1, _key(1), const Duration(seconds: 10));
      tracker.register(2, _key(2), const Duration(seconds: 10));

      tracker.removeForContact(_key(1));

      expect(tracker.confirm(1), isFalse);
      expect(tracker.confirm(2), isTrue);
    });
  });

  group('StatePersistence', () {
    NodeState stateWithText(String text) => NodeState(
          prefs: NodePrefs(nodeName: 'node'),
          queue: [QueuedMessage(senderKey: Uint8List(32), text: text)],
        );

    test('commits, saves, publishes, and reports storage', () async {
      final store = InMemoryNodeStore();
      var current = stateWithText('');
      var published = 0;
      final persistence = StatePersistence(
        store: store,
        storageQuotaBytes: virtualStorageQuotaBytes,
        snapshot: () => current,
        publish: (state) {
          current = state;
          published++;
        },
        isRetired: () => false,
        isResetting: () => false,
        isCurrent: (_) => true,
        onStateChanged: () {},
      );

      final candidate = stateWithText('hello');
      await persistence.commit(candidate);

      expect(published, 1);
      expect(current.queue.single.text, 'hello');
      expect((await store.load())?.queue.single.text, 'hello');
      expect(persistence.storageUsedBytes, current.storageBytes);
    });

    test('flush waits for queued saves before flushing the store', () async {
      final store = _BlockingStore();
      var current = stateWithText('');
      final persistence = StatePersistence(
        store: store,
        storageQuotaBytes: virtualStorageQuotaBytes,
        snapshot: () => current,
        publish: (state) => current = state,
        isRetired: () => false,
        isResetting: () => false,
        isCurrent: (_) => true,
        onStateChanged: () {},
      );

      final commit = persistence.commit(stateWithText('blocked'));
      await Future<void>.delayed(Duration.zero);
      expect(store.saveStarted, isTrue);
      expect(store.saveFinished, isFalse);

      var flushDone = false;
      final flush = persistence.flush().then((_) => flushDone = true);
      await Future<void>.delayed(Duration.zero);
      expect(flushDone, isFalse);
      expect(store.flushed, isFalse);

      store.saveGate.complete();
      await commit;
      await flush;
      expect(store.saveFinished, isTrue);
      expect(store.flushed, isTrue);
    });

    test('rejects retired, resetting, and stale-generation commits', () async {
      var retired = false;
      var resetting = false;
      var currentGeneration = 1;
      var published = 0;
      final persistence = StatePersistence(
        store: InMemoryNodeStore(),
        storageQuotaBytes: virtualStorageQuotaBytes,
        snapshot: () => stateWithText(''),
        publish: (_) => published++,
        isRetired: () => retired,
        isResetting: () => resetting,
        isCurrent: (generation) => generation == currentGeneration,
        onStateChanged: () {},
      );

      retired = true;
      await expectLater(
        persistence.commit(stateWithText('x')),
        throwsA(isA<CompanionOperationError>()
            .having((e) => e.code, 'code', errCodeBadState)),
      );

      retired = false;
      resetting = true;
      await expectLater(
        persistence.commit(stateWithText('x')),
        throwsA(isA<CompanionOperationError>()
            .having((e) => e.code, 'code', errCodeBadState)),
      );

      resetting = false;
      currentGeneration = 2;
      await persistence.commit(stateWithText('x'), identityGeneration: 1);
      expect(published, 0);
    });

    test('enforces the storage quota for growing mutations', () async {
      final persistence = StatePersistence(
        store: InMemoryNodeStore(),
        storageQuotaBytes: 400,
        snapshot: () => stateWithText(''),
        publish: (_) {},
        isRetired: () => false,
        isResetting: () => false,
        isCurrent: (_) => true,
        onStateChanged: () {},
      );

      await expectLater(
        persistence.commit(stateWithText('x' * 2000)),
        throwsA(isA<CompanionOperationError>()
            .having((e) => e.code, 'code', errCodeTableFull)),
      );
    });

    test('replace flushes, publishes, and notifies', () async {
      final store = InMemoryNodeStore();
      var current = stateWithText('');
      var notified = 0;
      final persistence = StatePersistence(
        store: store,
        storageQuotaBytes: virtualStorageQuotaBytes,
        snapshot: () => current,
        publish: (state) => current = state,
        isRetired: () => false,
        isResetting: () => false,
        isCurrent: (_) => true,
        onStateChanged: () => notified++,
      );

      await persistence.replace(stateWithText('fresh'));

      expect(current.queue.single.text, 'fresh');
      expect((await store.load())?.queue.single.text, 'fresh');
      expect(notified, 1);
    });
  });

  group('PacketTransport', () {
    test('transmits, accounts stats, and reports airtime', () async {
      final link = FakeDeviceLink(
        radioParams_: const RadioParams(
          frequencyHz: 915000000,
          bandwidthHz: 250000,
          spreadingFactor: 10,
          codingRate: 5,
        ),
      );
      await link.connect();
      final prefs = NodePrefs(
        frequencyHz: 915000000,
        bandwidthHz: 250000,
        spreadingFactor: 10,
        codingRate: 5,
      );
      final transport = PacketTransport(
        link: link,
        prefs: prefs,
        clock: VirtualClock(),
        localRouter: null,
        isBlocked: () => false,
        isRetired: () => false,
        isCurrent: (_) => true,
        effectiveFloodScope: () => null,
        publicKey: () => _key(1),
      );

      final packet = Packet()
        ..header = Packet.createHeader(payloadTypeTxtMsg, routeTypeFlood)
        ..payload = Uint8List.fromList([1, 2, 3]);

      await transport.transmit(packet, flood: true, scoped: true);
      expect(link.transmitted, hasLength(1));
      expect(transport.stats['sent'], 1);
      expect(transport.stats['flood_tx'], 1);
      expect(transport.airtimeMicrosFor(10), greaterThan(0));
      expect(
        transport.sendTimeoutMillisFor(packet, flood: true, scoped: true),
        greaterThan(0),
      );

      transport.addRxAirtime(10);
      transport.recordFrame(Packet()
        ..header = Packet.createHeader(payloadTypeTxtMsg, routeTypeDirect)
        ..payload = Uint8List.fromList([1]));
      expect(transport.stats['recv'], 1);
      expect(transport.stats['direct_rx'], 1);

      transport.recordMalformedFrame();
      expect(transport.stats['recv_errors'], 1);

      transport.resetCounters();
      expect(transport.stats['sent'], 0);
      expect(transport.stats['recv'], 0);
      await transport.waitForIdle();
    });

    test('suppresses transmissions while blocked', () async {
      final link = FakeDeviceLink();
      await link.connect();
      final transport = PacketTransport(
        link: link,
        prefs: NodePrefs(),
        clock: VirtualClock(),
        localRouter: null,
        isBlocked: () => true,
        isRetired: () => false,
        isCurrent: (_) => true,
        effectiveFloodScope: () => null,
        publicKey: () => _key(1),
      );

      await transport.transmit(
        Packet()
          ..header = Packet.createHeader(payloadTypeTxtMsg, routeTypeDirect)
          ..payload = Uint8List.fromList([1]),
        flood: false,
      );
      expect(link.transmitted, isEmpty);
    });
  });
}

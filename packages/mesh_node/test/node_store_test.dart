import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group('NodeState serialisation', () {
    test('round-trips through JSON', () {
      final contact = Contact(
        publicKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
        name: 'peer',
        advType: advTypeChat,
        flags: advertFlagHasName,
        outPathLen: 2,
        outPath: Uint8List.fromList([0xAB, 0xCD]),
        lastAdvertTimestamp: 1234,
        lastmod: 5678,
        gpsLat: 51.5,
        gpsLon: -0.12,
      );
      final state = NodeState(
        prefs: NodePrefs(
          nodeName: 'proxy',
          frequencyHz: 869000000,
          bandwidthHz: 125000,
          spreadingFactor: 11,
          latitude: 1.5,
          longitude: 2.5,
          telemetryModeBase: teleModeAllowAll,
        ),
        contacts: [contact],
        channels: {
          0: Channel(
            name: 'public',
            secret: Uint8List.fromList(
                LocalIdentity.defaultPublicChannelSecret),
          ),
          1: Channel(name: 'team', secret: Uint8List.fromList(List.filled(16, 7))),
        },
        queue: [
          QueuedMessage(
            senderKey: Uint8List.fromList(List<int>.generate(32, (i) => 255 - i)),
            txtType: txtTypePlain,
            timestamp: 42,
            text: 'hello',
            snr: -3.25,
            rssi: -80,
          ),
          QueuedMessage(
            senderKey: Uint8List(32),
            timestamp: 43,
            text: 'chan',
            isChannel: true,
            channelIdx: 1,
          ),
        ],
        advertPaths: {
          'AABBCCDDEEFF00': AdvertPath(
            publicKeyPrefix: Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00]),
            name: 'peer',
            pathLen: 1,
            path: Uint8List.fromList([0x11]),
            recvTimestamp: 99,
          ),
        },
      );

      final decoded = NodeState.fromJson(
          jsonDecode(jsonEncode(state.toJson())) as Map<String, Object?>);

      expect(decoded.prefs.nodeName, 'proxy');
      expect(decoded.prefs.frequencyHz, 869000000);
      expect(decoded.prefs.spreadingFactor, 11);
      expect(decoded.prefs.latitude, 1.5);
      expect(decoded.prefs.telemetryModeBase, teleModeAllowAll);

      expect(decoded.contacts, hasLength(1));
      final c = decoded.contacts.single;
      expect(c.publicKey, contact.publicKey);
      expect(c.name, 'peer');
      expect(c.outPathLen, 2);
      expect(c.outPath, [0xAB, 0xCD]);
      expect(c.gpsLat, 51.5);
      expect(c.gpsLon, -0.12);

      expect(decoded.channels.keys, containsAll([0, 1]));
      expect(decoded.channels[1]!.name, 'team');
      expect(decoded.channels[1]!.secret, List.filled(16, 7));

      expect(decoded.queue, hasLength(2));
      expect(decoded.queue[0].text, 'hello');
      expect(decoded.queue[0].snr, -3.25);
      expect(decoded.queue[1].isChannel, isTrue);
      expect(decoded.queue[1].channelIdx, 1);

      final p = decoded.advertPaths['AABBCCDDEEFF00']!;
      expect(p.name, 'peer');
      expect(p.path, [0x11]);
      expect(p.recvTimestamp, 99);
    });

    test('a JSON document with no version still loads', () {
      final decoded = NodeState.fromJson(<String, Object?>{});
      expect(decoded.contacts, isEmpty);
      expect(decoded.channels, isEmpty);
      expect(decoded.queue, isEmpty);
    });

    test('snapshot_is_deep_copy_before_async_save', () {
      final contact = Contact(
        publicKey: Uint8List(32)..[0] = 1,
        name: 'original',
        outPath: Uint8List.fromList([1, 2]),
        rawAdvert: Uint8List.fromList([3, 4]),
      );
      final queued = QueuedMessage(
        senderKey: Uint8List(32)..[0] = 2,
        text: 'queued',
        channelDataPayload: Uint8List.fromList([5, 6]),
      );
      final prefsKey = Uint8List.fromList([9, 9]);
      final channel = Channel(name: 'c', secret: Uint8List(16)..[0] = 7);
      final pathPrefix = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]);
      final settings = <String, String>{'key': 'value'};
      final state = NodeState(
        prefs: NodePrefs(nodeName: 'snapshot', defaultScopeKey: prefsKey),
        contacts: [contact],
        channels: {1: channel},
        queue: [queued],
        advertPaths: {
          'k': AdvertPath(
            publicKeyPrefix: pathPrefix,
            name: 'p',
            path: Uint8List.fromList([8]),
          ),
        },
        customSettings: settings,
      );

      // Mutate every nested object after the snapshot was taken.
      contact.name = 'mutated';
      contact.outPath[0] = 0xAA;
      contact.rawAdvert![0] = 0xBB;
      queued.senderKey[0] = 0xCC;
      queued.channelDataPayload![0] = 0xDD;
      channel.secret[0] = 0xEE;
      prefsKey[0] = 0xFF;
      pathPrefix[0] = 0x11;
      settings['key'] = 'mutated';

      expect(state.prefs.nodeName, 'snapshot');
      expect(state.prefs.defaultScopeKey, [9, 9]);
      expect(state.contacts.single.name, 'original');
      expect(state.contacts.single.outPath, [1, 2]);
      expect(state.contacts.single.rawAdvert, [3, 4]);
      expect(state.queue.single.text, 'queued');
      expect(state.queue.single.senderKey[0], 2);
      expect(state.queue.single.channelDataPayload, [5, 6]);
      expect(state.channels[1]!.secret[0], 7);
      expect(state.advertPaths['k']!.publicKeyPrefix[0], 1);
      expect(state.customSettings['key'], 'value');
    });

    test('storage_counts_utf8_compact_virtual_state_not_physical_flash_or_pretty_bytes',
        () {
      final state = NodeState(
        prefs: NodePrefs(nodeName: 'café'),
        customSettings: {'sensor': 'välue'},
      );
      final compact = jsonEncode(state.toJson());
      final pretty =
          const JsonEncoder.withIndent('  ').convert(state.toJson());

      expect(state.storageBytes, utf8.encode(compact).length);
      expect(state.storageBytes, greaterThan(compact.length),
          reason: 'UTF-8 bytes, not UTF-16 code units');
      expect(utf8.encode(pretty).length, greaterThan(state.storageBytes),
          reason: 'pretty file formatting is not charged to the partition');
    });

    test('used1025_rounds_to2_total4096', () async {
      expect(storageKibForBytes(1025), 2);
      expect(storageKibForBytes(1024), 1);
      expect(virtualStorageTotalKb, 4096);

      final node = MeshNode(
        identity: await LocalIdentity.fromSeed(Uint8List(32)..[0] = 3),
        link: FakeDeviceLink(
          batteryReading_: const BatteryReading(
            millivolts: 4000,
            storageUsedKb: 12,
            storageTotalKb: 1024,
          ),
        ),
      );
      addTearDown(node.stop);
      final reading = await node.getBatteryAndStorage();
      expect(reading.storageTotalKb, 4096);
      expect(reading.storageUsedKb, greaterThan(0),
          reason: 'fresh state still uses bytes');
      expect(node.storageUsedBytes, greaterThan(0));
    });

    test('load_legacy_schema_and_over_capacity_state_without_data_loss',
        () async {
      final contacts = List<Contact>.generate(
        virtualMaxContacts + 1,
        (i) => Contact(
          publicKey: Uint8List(32)
            ..[0] = i & 0xFF
            ..[1] = (i >> 8) & 0xFF,
          name: 'legacy$i',
          lastmod: i + 1,
        ),
      );
      final channels = <int, Channel>{
        for (var i = 0; i <= virtualMaxChannels; i++)
          i: Channel(
            name: 'ch$i',
            secret: Uint8List(16)..[0] = i,
          ),
      };
      final queue = List<QueuedMessage>.generate(
        513,
        (i) => QueuedMessage(
          senderKey: Uint8List(32),
          timestamp: i,
          text: 'legacy message $i',
          isChannel: true,
        ),
      );
      final paths = <String, AdvertPath>{
        for (var i = 0; i <= 64; i++)
          'P$i': AdvertPath(
            publicKeyPrefix: Uint8List(7),
            path: Uint8List(0),
            recvTimestamp: i,
          ),
      };
      final legacy = NodeState(
        prefs: NodePrefs(nodeName: 'legacy', pathHashMode: 1),
        contacts: contacts,
        channels: channels,
        queue: queue,
        advertPaths: paths,
      ).toJson();
      legacy['version'] = 1;
      (legacy['prefs'] as Map)
        ..remove('autoadd_max_hops')
        ..remove('timezone_offset_hours');
      legacy.remove('custom_settings');

      final decoded = NodeState.fromJson(legacy);
      expect(decoded.prefs.nodeName, 'legacy');
      expect(decoded.prefs.autoaddMaxHops, 0);
      expect(decoded.prefs.timezoneOffsetHours, 0);
      expect(decoded.contacts, hasLength(virtualMaxContacts + 1));
      expect(decoded.channels, hasLength(virtualMaxChannels + 1));
      expect(decoded.queue, hasLength(513));
      expect(decoded.advertPaths, hasLength(65));
      expect(decoded.customSettings, isEmpty);

      final store = InMemoryNodeStore();
      await store.save(decoded);
      final node = MeshNode(
        identity: await LocalIdentity.fromSeed(Uint8List(32)..[0] = 4),
        link: FakeDeviceLink(),
        store: store,
      );
      await node.load();
      expect(node.contacts, hasLength(virtualMaxContacts + 1));
      expect(node.maxChannels, virtualMaxChannels);
      await expectLater(
        node.addUpdateContact(Contact(
          publicKey: Uint8List(32)
            ..[0] = 0xEE
            ..[1] = 0xEE,
          name: 'new',
        )),
        throwsA(isA<CompanionOperationError>()),
      );
      expect(node.contacts, hasLength(virtualMaxContacts + 1),
          reason: 'over-capacity legacy state is preserved');
      node.stop();
    });

    test('drops contacts with a malformed public key', () {
      final decoded = NodeState.fromJson(<String, Object?>{
        'contacts': [
          {'public_key': '00', 'name': 'bad'},
          {'public_key': bytesToHex(Uint8List(32)), 'name': 'good'},
        ],
      });
      expect(decoded.contacts, hasLength(1));
      expect(decoded.contacts.single.name, 'good');
    });
  });

  group('JsonNodeStore', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('mesh_node_store');
    });

    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    test('load returns null when the file does not exist', () async {
      final store = JsonNodeStore(file: File('${dir.path}/missing.json'));
      expect(await store.load(), isNull);
    });

    test('saves and reloads state', () async {
      final file = File('${dir.path}/nested/state.json');
      final store = JsonNodeStore(file: file, pretty: true);
      await store.save(NodeState(
        prefs: NodePrefs(nodeName: 'persisted'),
        contacts: [
          Contact(publicKey: Uint8List(32), name: 'c'),
        ],
      ));

      expect(file.existsSync(), isTrue);
      final loaded = await JsonNodeStore(file: file).load();
      expect(loaded!.prefs.nodeName, 'persisted');
      expect(loaded.contacts.single.name, 'c');
    });

    test('recovers from a corrupt file', () async {
      final file = File('${dir.path}/bad.json');
      await file.writeAsString('{not json');
      expect(await JsonNodeStore(file: file).load(), isNull);
    });

    test('serialises concurrent saves last-write-wins', () async {
      final file = File('${dir.path}/state.json');
      final store = JsonNodeStore(file: file);
      final a = store.save(NodeState(prefs: NodePrefs(nodeName: 'first')));
      final b = store.save(NodeState(prefs: NodePrefs(nodeName: 'second')));
      await Future.wait([a, b]);
      expect((await store.load())!.prefs.nodeName, 'second');
    });

    test('failed_save_is_observable_and_next_save_still_runs', () async {
      // A regular file where the parent directory should be makes the write
      // fail with a real filesystem error.
      final blocker = File('${dir.path}/blocker');
      await blocker.writeAsString('x');
      final file = File('${blocker.path}/state.json');
      final store = JsonNodeStore(file: file);

      await expectLater(
        store.save(NodeState(prefs: NodePrefs(nodeName: 'first'))),
        throwsA(isA<FileSystemException>()),
      );

      await blocker.delete();
      await store.save(NodeState(prefs: NodePrefs(nodeName: 'second')));
      await store.flush();
      expect((await store.load())!.prefs.nodeName, 'second');
    });

    test('flush_prevents_old_snapshot_resurrecting_reset_state', () async {
      final file = File('${dir.path}/reset.json');
      final store = JsonNodeStore(file: file);
      final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 5);
      final node = MeshNode(
        identity: id,
        link: FakeDeviceLink(),
        store: store,
        prefs: NodePrefs(nodeName: 'old name'),
      );
      addTearDown(node.stop);

      await node.setAdvertName('old name');
      await node.flush();
      await node.resetVirtualState();

      final loaded = await store.load();
      expect(loaded!.prefs.nodeName, 'MeshChameleon');
      expect(loaded.contacts, isEmpty);
      expect(loaded.queue, isEmpty);
      expect(node.identity.publicKey, id.publicKey,
          reason: 'reset keeps the identity');
    });
  });

  group('MeshNode persistence', () {
    late FakeRadioBus bus;
    late LocalIdentity aliceId;
    late LocalIdentity bobId;
    late FakeDeviceLink aliceLink;
    late FakeDeviceLink bobLink;
    late MeshNode alice;
    late MeshNode bob;
    late InMemoryNodeStore store;

    setUp(() async {
      bus = FakeRadioBus();
      aliceId = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 1);
      bobId = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 2);
      aliceLink = FakeDeviceLink(bus: bus);
      bobLink = FakeDeviceLink(bus: bus);
      await aliceLink.connect();
      await bobLink.connect();
      store = InMemoryNodeStore();
      alice = MeshNode(
        identity: aliceId,
        link: aliceLink,
        prefs: NodePrefs(nodeName: 'alice'),
        store: store,
      )..start();
      bob = MeshNode(
        identity: bobId,
        link: bobLink,
        prefs: NodePrefs(nodeName: 'bob'),
      )..start();
    });

    tearDown(() {
      alice.stop();
      bob.stop();
    });

    test('persists learned contacts and restores them on reload', () async {
      await bob.advertise();
      await pump();

      final saved = await store.load();
      expect(saved, isNotNull);
      expect(saved!.contacts, hasLength(1));
      expect(saved.contacts.single.name, 'bob');

      final relaunched = MeshNode(
        identity: aliceId,
        link: aliceLink,
        store: store,
      );
      await relaunched.load();
      expect(relaunched.contacts, hasLength(1));
      expect(relaunched.contacts.single.publicKey, bobId.publicKey);
      // The default public channel is always present after a load.
      expect(relaunched.channels.containsKey(0), isTrue);
    });

    test('migrates the persisted default channel name to Public', () async {
      await store.save(NodeState(
        prefs: NodePrefs(),
        channels: {
          0: Channel(
            name: 'public',
            secret: Uint8List.fromList(
                LocalIdentity.defaultPublicChannelSecret),
          ),
        },
      ));

      final relaunched = MeshNode(
        identity: aliceId,
        link: aliceLink,
        store: store,
      );
      await relaunched.load();
      expect(relaunched.getChannel(0)?.name, 'Public');
    });

    test('persists preference and channel changes', () async {
      await alice.setAdvertName('renamed');
      await alice.setAdvertLatLon(12.5, -3.25);
      await alice.setChannel(1, 'team', Uint8List.fromList(List.filled(16, 9)));

      final saved = await store.load();
      expect(saved!.prefs.nodeName, 'renamed');
      expect(saved.prefs.latitude, 12.5);
      expect(saved.prefs.longitude, -3.25);
      expect(saved.channels[1]!.name, 'team');

      final relaunched = MeshNode(identity: aliceId, link: aliceLink, store: store);
      await relaunched.load();
      expect(relaunched.prefs.nodeName, 'renamed');
      expect(relaunched.channels[1]!.secret, List.filled(16, 9));
    });

    test('persists the offline message queue across restart', () async {
      await bob.sendChannelMessage(0, 'hello alice');
      await pump();

      expect((await store.load())!.queue, hasLength(1));

      final relaunched = MeshNode(identity: aliceId, link: aliceLink, store: store);
      await relaunched.load();
      final msg = await relaunched.syncNextMessage();
      expect(msg, isNotNull);
      expect(msg!.text, 'bob: hello alice');
      expect(await relaunched.syncNextMessage(), isNull);
    });

    test('drops the oldest queued messages on overflow', () async {
      final bounded = MeshNode(
        identity: aliceId,
        link: aliceLink,
        maxQueueSize: 2,
        store: store,
      )..start();
      await bob.sendChannelMessage(0, 'msg1');
      await pump();
      await bob.sendChannelMessage(0, 'msg2');
      await pump();
      await bob.sendChannelMessage(0, 'msg3');
      await pump();

      expect((await bounded.syncNextMessage())!.text, 'bob: msg2');
      expect((await bounded.syncNextMessage())!.text, 'bob: msg3');
      expect(await bounded.syncNextMessage(), isNull);
      bounded.stop();
    });

    test('quota_rejects_candidate_without_publishing_or_losing_old_contact',
        () async {
      final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 6);
      final store = InMemoryNodeStore(maxBytes: 4096);
      final node = MeshNode(
        identity: id,
        link: FakeDeviceLink(),
        store: store,
        storageQuotaBytes: 4096,
      )..start();
      addTearDown(node.stop);

      final old = Contact(
        publicKey: Uint8List(32)..[0] = 1,
        name: 'old',
      );
      await node.addUpdateContact(old);
      final big = Contact(
        publicKey: Uint8List(32)..[0] = 2,
        name: 'big',
        rawAdvert: Uint8List(8000),
      );

      await expectLater(
        node.addUpdateContact(big),
        throwsA(isA<CompanionOperationError>()
            .having((e) => e.code, 'code', errCodeTableFull)),
      );
      expect(node.contacts, hasLength(1));
      expect(node.contacts.single.name, 'old');
      final saved = await store.load();
      expect(saved!.contacts.single.name, 'old');
    });

    test('queue_drops_oldest_for_count_and_quota', () async {
      final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 7);
      final channel = Channel(
        name: 'Public',
        secret: Uint8List.fromList(LocalIdentity.defaultPublicChannelSecret),
      );

      // Count cap: the newest three of four messages survive.
      final countLink = FakeDeviceLink();
      await countLink.connect();
      final counted = MeshNode(
        identity: id,
        link: countLink,
        maxQueueSize: 3,
      )..start();
      for (var i = 0; i < 4; i++) {
        countLink.deliver(
          6.0,
          -70,
          _groupDataPacket(channel, Uint8List.fromList([i])),
        );
        await pump();
      }
      expect((await counted.syncNextMessage())!.channelDataPayload, [1]);
      expect((await counted.syncNextMessage())!.channelDataPayload, [2]);
      expect((await counted.syncNextMessage())!.channelDataPayload, [3]);
      expect(await counted.syncNextMessage(), isNull);
      counted.stop();

      // Quota cap: one small message fits, two do not; the oldest is dropped.
      final emptyBytes = NodeState(
        prefs: NodePrefs(),
        channels: {0: channel},
      ).storageBytes;
      final oneBytes = NodeState(
        prefs: NodePrefs(),
        channels: {0: channel},
        queue: [_queuedChannelData(Uint8List.fromList([1]))],
      ).storageBytes;
      final quota = emptyBytes + (oneBytes - emptyBytes) + 20;

      final quotaLink = FakeDeviceLink();
      await quotaLink.connect();
      final bounded = MeshNode(
        identity: id,
        link: quotaLink,
        storageQuotaBytes: quota,
        store: InMemoryNodeStore(maxBytes: quota),
      )..start();

      quotaLink.deliver(
        6.0,
        -70,
        _groupDataPacket(channel, Uint8List.fromList([1])),
      );
      await pump();
      expect((await bounded.getStats(statsTypeCore))['queue_len'], 1);

      quotaLink.deliver(
        6.0,
        -70,
        _groupDataPacket(channel, Uint8List.fromList([2])),
      );
      await pump();
      expect((await bounded.getStats(statsTypeCore))['queue_len'], 1);

      // A message that cannot fit even alone is dropped without evicting the
      // current queue.
      quotaLink.deliver(
        6.0,
        -70,
        _groupDataPacket(channel, Uint8List(255)),
      );
      await pump();
      expect((await bounded.getStats(statsTypeCore))['queue_len'], 1);
      expect((await bounded.syncNextMessage())!.channelDataPayload, [2]);
      expect(await bounded.syncNextMessage(), isNull);
      bounded.stop();
    });

    test('disk_full_is_err5_not_quota_err3', () async {
      final dir = await Directory.systemTemp.createTemp('mesh_node_disk_full');
      addTearDown(() => dir.delete(recursive: true));
      final blocker = File('${dir.path}/blocker');
      await blocker.writeAsString('x');
      final store = JsonNodeStore(file: File('${blocker.path}/state.json'));
      final node = MeshNode(
        identity: await LocalIdentity.fromSeed(Uint8List(32)..[0] = 8),
        link: FakeDeviceLink(),
        store: store,
      )..start();
      addTearDown(node.stop);

      await expectLater(
        node.setAdvertName('new name'),
        throwsA(isA<CompanionOperationError>()
            .having((e) => e.code, 'code', errCodeFileIoError)),
      );
      expect(node.prefs.nodeName, 'MeshChameleon');
    });

    test('legacy_over_quota_state_allows_shrinking_but_not_growth', () async {
      final dir = await Directory.systemTemp.createTemp('mesh_node_overquota');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/state.json');
      final contact =
          Contact(publicKey: Uint8List(32)..[0] = 1, name: 'legacy');
      final keep = Contact(
        publicKey: Uint8List(32)..[0] = 2,
        name: 'keep',
        rawAdvert: Uint8List(2000),
      );
      final legacy = NodeState(
        prefs: NodePrefs(nodeName: 'legacy'),
        contacts: [contact, keep],
      );
      await file.writeAsString(jsonEncode(legacy.toJson()));

      final store = JsonNodeStore(file: file, maxBytes: 1024);
      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.storageBytes, greaterThan(1024));

      final node = MeshNode(
        identity: await LocalIdentity.fromSeed(Uint8List(32)..[0] = 9),
        link: FakeDeviceLink(),
        store: store,
        storageQuotaBytes: 1024,
      );
      await node.load();
      expect(node.contacts, hasLength(2));

      // A shrinking mutation is allowed even though the state remains over
      // quota; growth is rejected.
      await node.removeContact(contact.publicKey);
      expect(node.contacts.single.name, 'keep');
      expect((await store.load())!.contacts.single.name, 'keep');

      await expectLater(
        node.addUpdateContact(Contact(
          publicKey: Uint8List(32)
            ..[0] = 3
            ..[1] = 3,
          name: 'new',
        )),
        throwsA(isA<CompanionOperationError>()
            .having((e) => e.code, 'code', errCodeTableFull)),
      );
      node.stop();
    });

    test('timezone_persists_but_virtual_time_offset_does_not', () async {
      final store = InMemoryNodeStore();
      final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 12);
      final firstClock = VirtualClock(
        hostWallClock: () => DateTime.fromMillisecondsSinceEpoch(100000),
        monotonicClock: () => Duration.zero,
      );
      final first = MeshNode(
        identity: id,
        link: FakeDeviceLink(),
        store: store,
        clock: firstClock,
      );
      expect(first.setTime(500), isTrue);
      await first.setTimezoneOffsetHours(5);
      first.stop();

      expect((await store.load())!.prefs.timezoneOffsetHours, 5);
      final secondClock = VirtualClock(
        hostWallClock: () => DateTime.fromMillisecondsSinceEpoch(200000),
        monotonicClock: () => Duration.zero,
      );
      final second = MeshNode(
        identity: id,
        link: FakeDeviceLink(),
        store: store,
        clock: secondClock,
      );
      await second.load();
      expect(second.timezoneOffsetHours, 5);
      expect(second.getTime(), 200,
          reason: 'the runtime virtual offset is not persisted');
      second.stop();
    });

    test('memory_store_enforces_same_virtual_quota', () async {
      final store = InMemoryNodeStore(maxBytes: 1024);
      await expectLater(
        store.save(NodeState(prefs: NodePrefs(nodeName: 'x' * 2000))),
        throwsA(isA<NodeStorageQuotaError>()),
      );
    });

    test('advert_path_cache_is_capped_at_64', () async {
      expect(defaultOfflineQueueSize, 512);
      final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 11);
      final link = FakeDeviceLink();
      await link.connect();
      final node = MeshNode(identity: id, link: link)..start();
      addTearDown(node.stop);

      for (var i = 0; i < 66; i++) {
        final peer = await LocalIdentity.fromSeed(
          Uint8List(32)..[0] = i + 20,
        );
        final advert = await PacketBuilder.createAdvert(
          identity: peer,
          name: 'p$i',
          lat: 0,
          lon: 0,
          flags: advTypeChat,
          flood: true,
          timestamp: 1700000000 + i,
        );
        link.deliver(6.0, -70, advert.writeTo());
        await pump();
      }
      expect(node.contacts, hasLength(66));
      expect(node.advertPathCacheLength, maxAdvertPathCacheEntries);
    });
  });
}

Uint8List _groupDataPacket(Channel channel, Uint8List data) {
  final secret = Uint8List(32);
  secret.setRange(0, channel.secret.length.clamp(0, 32), channel.secret);
  final channelHash = CryptoUtils.sha256(secret.sublist(0, 16))[0];
  final plaintext = BufferWriter()
    ..writeUInt16Le(0x1234)
    ..writeByte(data.length)
    ..writeBytes(data);
  final cipher = CryptoUtils.encryptThenMac(
      secret.sublist(0, 16), secret, plaintext.toBytes());
  return (Packet()
        ..header = Packet.createHeader(payloadTypeGrpData, routeTypeFlood)
        ..pathLenByte = 0
        ..payload = Uint8List.fromList([channelHash, ...cipher]))
      .writeTo();
}

QueuedMessage _queuedChannelData(Uint8List data) => QueuedMessage(
      senderKey: Uint8List(32),
      isChannel: true,
      channelIdx: 0,
      pathLen: 0xFF,
      snr: 6.0,
      rssi: -70,
      channelDataType: 0x1234,
      channelDataPayload: Uint8List.fromList(data),
    );

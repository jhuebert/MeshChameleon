import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

    test('persists preference and channel changes', () async {
      alice.setAdvertName('renamed');
      alice.setAdvertLatLon(12.5, -3.25);
      alice.setChannel(1, 'team', Uint8List.fromList(List.filled(16, 9)));

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
      final msg = relaunched.syncNextMessage();
      expect(msg, isNotNull);
      expect(msg!.text, 'bob: hello alice');
      expect(relaunched.syncNextMessage(), isNull);
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

      expect(bounded.syncNextMessage()!.text, 'bob: msg2');
      expect(bounded.syncNextMessage()!.text, 'bob: msg3');
      expect(bounded.syncNextMessage(), isNull);
      bounded.stop();
    });
  });
}

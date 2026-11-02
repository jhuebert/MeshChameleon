import 'dart:async';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

/// An [InMemoryNodeStore] whose next save can be held open, so a test can
/// interleave another mutation with an in-flight commit.
class _GatedStore extends InMemoryNodeStore {
  Completer<void>? _gate;
  Completer<void>? _started;
  bool _blocking = false;

  void blockNextSave() {
    _gate = Completer<void>();
    _started = Completer<void>();
    _blocking = true;
  }

  Future<void> get started => _started!.future;

  void release() => _gate!.complete();

  @override
  Future<void> save(NodeState state) async {
    if (_blocking) {
      _blocking = false;
      _started!.complete();
      await _gate!.future;
    }
    await super.save(state);
  }
}

Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 20));

class _AdvertSink extends NoopCompanionPushSink {
  int newAdverts = 0;
  int contactsFull = 0;

  @override
  void pushNewAdvert(Uint8List contactFrame) => newAdverts++;

  @override
  void pushContactsFull() => contactsFull++;
}

void main() {
  late LocalIdentity identity;
  late FakeDeviceLink link;
  late _GatedStore store;
  late MeshNode node;

  setUp(() async {
    identity = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 1);
    link = FakeDeviceLink();
    await link.connect();
    store = _GatedStore();
    node = MeshNode(identity: identity, link: link, store: store)..start();
  });

  tearDown(() => node.stop());

  test('syncNextMessage and a concurrent inbound message both survive',
      () async {
    link.deliver(
      6.0,
      -70,
      PacketBuilder.createGroupText(
        channel: node.getChannel(0)!,
        message: 'A',
        senderName: 'peer',
        timestamp: 100,
      ).writeTo(),
    );
    await pump();

    store.blockNextSave();
    final firstSync = node.syncNextMessage();
    await store.started;

    // This arrives while the first sync is blocked in the save. The old code
    // built its candidate from the pre-sync live queue, so the save that
    // followed resurrected the consumed message.
    link.deliver(
      6.0,
      -70,
      PacketBuilder.createGroupText(
        channel: node.getChannel(0)!,
        message: 'B',
        senderName: 'peer',
        timestamp: 101,
      ).writeTo(),
    );
    await pump();

    store.release();
    final first = await firstSync;
    await pump();
    expect(first?.text, 'peer: A');

    final second = await node.syncNextMessage();
    expect(second?.text, 'peer: B');
    expect(await node.syncNextMessage(), isNull);
  });

  test('a queued contact commit preserves a radio readback', () async {
    store.blockNextSave();
    final blocker = node.setPathHashMode(1);
    await store.started;

    final contact = Contact(
      publicKey: Uint8List(32)..[0] = 9,
      name: 'peer',
      lastmod: 1,
    );
    final addContact = node.addUpdateContact(contact);

    // The readback mutates prefs while the contact commit is still queued.
    // A candidate captured before the queue would publish the old frequency.
    node.syncRadioParams(const RadioParams(
      frequencyHz: 915500000,
      bandwidthHz: 250000,
      spreadingFactor: 10,
      codingRate: 5,
    ));

    store.release();
    await blocker;
    await addContact;
    await node.flush();

    expect(node.prefs.frequencyHz, 915500000);
    expect(node.getContactByKey(contact.publicKey), isNotNull);
    final persisted = await store.load();
    expect(persisted!.prefs.frequencyHz, 915500000);
    expect(persisted.contacts.single.name, 'peer');
  });

  test('a quota failure still reports a discovered advert', () async {
    final peer = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 2);
    final prefs = NodePrefs(manualAddContacts: 1, autoaddConfig: 0);
    final empty = NodeState(
      prefs: prefs,
      channels: {0: defaultPublicChannel()},
    );
    final quota = empty.storageBytes;
    final limitedLink = FakeDeviceLink();
    await limitedLink.connect();
    final limited = MeshNode(
      identity: identity,
      link: limitedLink,
      prefs: prefs,
      storageQuotaBytes: quota,
      store: InMemoryNodeStore(maxBytes: quota),
    )..start();
    addTearDown(limited.stop);
    final sink = _AdvertSink();
    limited.setPushSink(sink);

    final advert = await PacketBuilder.createAdvert(
      identity: peer,
      name: 'peer',
      lat: 0,
      lon: 0,
      flags: advTypeChat,
      flood: true,
      timestamp: 1700000000,
    );
    limitedLink.deliver(6.0, -70, advert.writeTo());
    await pump();

    expect(sink.newAdverts, 1,
        reason: 'discovery still notifies even when path caching fails');
    expect(sink.contactsFull, 0);
    expect(limited.contacts, isEmpty);
  });

  test('a quota failure while storing a contact reports a full table',
      () async {
    final peer = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 3);
    final empty = NodeState(
      prefs: NodePrefs(),
      channels: {0: defaultPublicChannel()},
    );
    final quota = empty.storageBytes;
    final limitedLink = FakeDeviceLink();
    await limitedLink.connect();
    final limited = MeshNode(
      identity: identity,
      link: limitedLink,
      storageQuotaBytes: quota,
      store: InMemoryNodeStore(maxBytes: quota),
    )..start();
    addTearDown(limited.stop);
    final sink = _AdvertSink();
    limited.setPushSink(sink);

    final advert = await PacketBuilder.createAdvert(
      identity: peer,
      name: 'peer',
      lat: 0,
      lon: 0,
      flags: advTypeChat,
      flood: true,
      timestamp: 1700000001,
    );
    limitedLink.deliver(6.0, -70, advert.writeTo());
    await pump();

    expect(sink.newAdverts, 1);
    expect(sink.contactsFull, 1);
    expect(limited.contacts, isEmpty);
  });
}

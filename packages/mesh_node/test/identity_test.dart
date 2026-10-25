import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 30));

class _FakeIdentityPersistence implements VirtualIdentityPersistence {
  _FakeIdentityPersistence(this.stored);

  LocalIdentity? stored;
  Object? saveError;
  Object? loadError;
  bool commitBeforeSaveError = false;

  @override
  Future<LocalIdentity?> load() async {
    if (loadError != null) throw loadError!;
    return stored;
  }

  @override
  Future<void> save(LocalIdentity identity) async {
    if (saveError != null) {
      if (commitBeforeSaveError) stored = identity;
      throw saveError!;
    }
    stored = identity;
  }
}

Future<LocalIdentity> _seed(int value) =>
    LocalIdentity.fromSeed(Uint8List(32)..[0] = value);

class _LeakyJob {
  _LeakyJob(this.at, this.action);
  final int at;
  final void Function() action;
  bool done = false;
  bool cancelled = false;
}

class _LeakyScheduler implements MeshScheduler {
  int now = 0;
  final List<_LeakyJob> jobs = [];

  @override
  CancelScheduled schedule(Duration delay, void Function() action) {
    final job = _LeakyJob(now + delay.inMilliseconds, action);
    jobs.add(job);
    // Model a timer callback that was already queued when cancel() ran.
    return () => job.cancelled = false;
  }

  void advance(Duration delay) {
    now += delay.inMilliseconds;
    var ran = true;
    while (ran) {
      ran = false;
      for (final job in List<_LeakyJob>.of(jobs)) {
        if (!job.done && !job.cancelled && job.at <= now) {
          job.done = true;
          job.action();
          ran = true;
        }
      }
    }
  }
}

void main() {
  test('export_returns_virtual64_not_different_physical64', () async {
    final active = await _seed(1);
    final physical = await _seed(99);
    final link = FakeDeviceLink(devicePrivateKey: physical.meshcore64);
    final node = MeshNode(identity: active, link: link);

    final exported = await node.exportPrivateKey();
    expect(exported, active.meshcore64);
    expect(exported, isNot(physical.meshcore64));
    expect(link.exportPrivateKeyRequests, 0);
    expect(link.calls, isNot(contains('exportPrivateKey')));
  });

  test('network_import_rejects_short32_prefix00_ff_and_ecdh_invalid_keys',
      () async {
    final old = await _seed(2);
    final link = FakeDeviceLink();
    final node = MeshNode(identity: old, link: link);
    final prefix00 = hexToBytes(
      '904bfc6464fab00f290b0af4281c582995b553cd3183ce295323d62dfacc325a'
      'f95f5f99de94f6f17e62634498d53c2d0d13c5f39425ce0b298e4cb9a150db7f',
    );
    final prefixFf = hexToBytes(
      '7072e90de6cbc83fc7f634fc9d16f9fbd44a7533fdbd6740edcc4700cd840d79'
      '5ccb1c02d93bc82cad1bce56544aeeab3ef722891547abe282498e6f452c241d',
    );
    final invalidEcdh = hexToBytes(
      '0137dddb67ad806e5073c8ee561af2980cf721dbde3f7ace16729d4e8fb2613a'
      '5ed63e9c3f6ff001ffdd8f93dc4772cb3a5994a23c00184cc1aea33e4ff8b936',
    );
    for (final key in [
      Uint8List(32),
      prefix00,
      prefixFf,
      invalidEcdh,
    ]) {
      await expectLater(
        node.importPrivateKey(key),
        throwsA(isA<CompanionOperationError>()
            .having((e) => e.code, 'code', errCodeIllegalArg)),
      );
      expect(node.identity.publicKey, old.publicKey);
      expect(node.identityGeneration, 0);
    }
    expect(link.calls.where((c) => c.startsWith('sendRaw')), isEmpty);
    expect(link.calls, isNot(contains('exportPrivateKey')));
  });

  test('storage_failure_keeps_old_active_key_and_returns_err5', () async {
    final old = await _seed(3);
    final candidate = await _seed(4);
    final persistence = _FakeIdentityPersistence(old)
      ..saveError = const FileSystemException('write failed');
    final node = MeshNode(
      identity: old,
      link: FakeDeviceLink(),
      identityPersistence: persistence,
    );

    await expectLater(
      node.importPrivateKey(candidate.meshcore64),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeFileIoError)),
    );
    expect(node.identity.publicKey, old.publicKey);
    expect(node.identityGeneration, 0);
    expect(node.identityPaused, isFalse);
    expect(node.identityDiagnostic, contains('previous key'));
  });

  test(
      'save_error_readback_candidate_is_success_old_key_is_err5_unreadable_pauses',
      () async {
    final old = await _seed(5);
    final candidate = await _seed(6);

    final committed = _FakeIdentityPersistence(old)
      ..saveError = const FileSystemException('reported failure')
      ..commitBeforeSaveError = true;
    final committedNode = MeshNode(
      identity: old,
      link: FakeDeviceLink(),
      identityPersistence: committed,
    );
    await committedNode.importPrivateKey(candidate.meshcore64);
    expect(committedNode.identity.publicKey, candidate.publicKey);
    expect(committedNode.identityGeneration, 1);
    expect(committedNode.identityDiagnostic, contains('commit'));

    final rolledBack = _FakeIdentityPersistence(old)
      ..saveError = const FileSystemException('write failed');
    final rolledBackNode = MeshNode(
      identity: old,
      link: FakeDeviceLink(),
      identityPersistence: rolledBack,
    );
    await expectLater(
      rolledBackNode.importPrivateKey(candidate.meshcore64),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeFileIoError)),
    );
    expect(rolledBackNode.identity.publicKey, old.publicKey);
    expect(rolledBackNode.identityPaused, isFalse);

    final unreadable = _FakeIdentityPersistence(old)
      ..saveError = const FileSystemException('write failed')
      ..loadError = const FileSystemException('read failed');
    final unreadableNode = MeshNode(
      identity: old,
      link: FakeDeviceLink(),
      identityPersistence: unreadable,
    );
    await expectLater(
      unreadableNode.importPrivateKey(candidate.meshcore64),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeFileIoError)),
    );
    expect(unreadableNode.identity.publicKey, old.publicKey);
    expect(unreadableNode.identityPaused, isTrue);
    await expectLater(
      unreadableNode.exportPrivateKey(),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeBadState)),
    );
  });

  test('import_retains_contacts_channels_prefs_queue_but_clears_sessions',
      () async {
    final old = await _seed(7);
    final candidate = await _seed(8);
    final peer = await _seed(21);
    final store = InMemoryNodeStore();
    await store.save(NodeState(
      prefs: NodePrefs(nodeName: 'kept name', advertLocPolicy: 1),
      contacts: [
        Contact(
          publicKey: peer.publicKey,
          name: 'kept peer',
          outPath: Uint8List.fromList([1, 2]),
          outPathLen: 2,
        ),
      ],
      channels: {
        1: Channel(
          name: 'kept channel',
          secret: Uint8List.fromList(List.filled(16, 9)),
        ),
      },
      queue: [
        QueuedMessage(
          senderKey: peer.publicKey,
          text: 'kept message',
          timestamp: 123,
        ),
      ],
    ));
    final persistence = _FakeIdentityPersistence(old);
    final link = FakeDeviceLink();
    final node = MeshNode(
      identity: old,
      link: link,
      store: store,
      identityPersistence: persistence,
    );
    await node.load();
    node.start();
    addTearDown(node.stop);

    // Open a keep-alive session before the import.
    final login = await node.sendLogin(peer.publicKey, 'pw');
    expect(login.success, isTrue);
    final secret = await peer.sharedSecret(old.publicKey);
    final body = Uint8List(13)
      ..setRange(
        0,
        4,
        (BufferWriter()..writeUInt32Le(login.expectedAck!)).toBytes(),
      )
      ..[4] = 0 // login success
      ..[5] = 4; // 64s keep-alive
    final cipher = CryptoUtils.encryptThenMac(
      secret.sublist(0, 16),
      secret,
      body,
    );
    link.deliver(
      6.0,
      -70,
      (Packet()
            ..header = Packet.createHeader(
              payloadTypeResponse,
              routeTypeDirect,
            )
            ..payload = Uint8List.fromList([
              old.publicKey[0],
              peer.publicKey[0],
              ...cipher,
            ]))
          .writeTo(),
    );
    await pump();
    expect(node.hasConnection(peer.publicKey), isTrue);

    await node.importPrivateKey(candidate.meshcore64);

    expect(node.identity.publicKey, candidate.publicKey);
    expect(node.prefs.nodeName, 'kept name');
    expect(node.prefs.advertLocPolicy, 1);
    expect(node.getContactByKey(peer.publicKey)?.name, 'kept peer');
    expect(node.getChannel(1)?.name, 'kept channel');
    final queued = await node.syncNextMessage();
    expect(queued?.text, 'kept message');
    expect(node.hasConnection(peer.publicKey), isFalse);
  });

  test('info_signing_dm_advert_export_all_switch_together', () async {
    final bus = FakeRadioBus();
    final aliceOld = await _seed(1);
    final aliceNew = await _seed(9);
    final bobId = await _seed(2);
    final aliceLink = FakeDeviceLink(bus: bus);
    final bobLink = FakeDeviceLink(bus: bus);
    await aliceLink.connect();
    await bobLink.connect();
    final alice = MeshNode(
      identity: aliceOld,
      link: aliceLink,
      prefs: NodePrefs(nodeName: 'alice'),
    )..start();
    final bob = MeshNode(
      identity: bobId,
      link: bobLink,
      prefs: NodePrefs(nodeName: 'bob'),
    )..start();
    addTearDown(alice.stop);
    addTearDown(bob.stop);
    addTearDown(aliceLink.disconnect);
    addTearDown(bobLink.disconnect);

    await bob.addUpdateContact(Contact(
      publicKey: aliceOld.publicKey,
      name: 'alice-old',
    ));
    await alice.addUpdateContact(Contact(
      publicKey: bobId.publicKey,
      name: 'bob',
    ));
    await bob.addUpdateContact(Contact(
      publicKey: aliceNew.publicKey,
      name: 'alice-new',
    ));

    await alice.importPrivateKey(aliceNew.meshcore64);
    expect(alice.getPublicKey(), aliceNew.publicKey);
    expect(await alice.exportPrivateKey(), aliceNew.meshcore64);

    final message = Uint8List.fromList('switch check'.codeUnits);
    final signature = await alice.sign(message);
    expect(
      await LocalIdentity.verify(message, signature, aliceNew.publicKey),
      isTrue,
    );
    expect(
      await LocalIdentity.verify(message, signature, aliceOld.publicKey),
      isFalse,
    );

    await alice.advertise();
    await pump();
    final advertised = bob.getContactByKey(aliceNew.publicKey);
    expect(advertised, isNotNull);
    expect(advertised!.lastAdvertTimestamp, greaterThan(0));

    final sent = await alice.sendTextMessage(bobId.publicKey, 'new identity');
    expect(sent.success, isTrue);
    await pump();
    final received = await bob.syncNextMessage();
    expect(received, isNotNull);
    expect(received!.text, 'new identity');
    expect(received.senderKey, aliceNew.publicKey);
  });

  test('inflight_old_generation_cannot_emit_push_or_mutate_new_identity',
      () async {
    final old = await _seed(13);
    final candidate = await _seed(14);
    final sender = await _seed(15);
    final scheduler = _LeakyScheduler();
    final link = FakeDeviceLink();
    final node = MeshNode(
      identity: old,
      link: link,
      scheduler: scheduler,
      identityPersistence: _FakeIdentityPersistence(old),
    )..start();
    addTearDown(node.stop);
    await node.addUpdateContact(Contact(
      publicKey: sender.publicKey,
      name: 'sender',
    ));
    // Drop the battery lifecycle job so only the semantic ACK job remains.
    scheduler.jobs.clear();

    final (packet, _) = await PacketBuilder.createTextMessage(
      contact: Contact(publicKey: old.publicKey, name: 'old alice'),
      identity: sender,
      message: 'old generation',
      timestamp: 1,
    );
    link.deliver(6.0, -70, packet.writeTo());
    await pump(); // old handler schedules its ACK
    final transmitsBefore =
        link.calls.where((c) => c == 'sendRawPacket').length;

    await node.importPrivateKey(candidate.meshcore64);
    // The old timer callback is already queued and cancel() cannot stop it.
    scheduler.advance(const Duration(seconds: 1));
    await pump();

    expect(
      link.calls.where((c) => c == 'sendRawPacket').length,
      transmitsBefore,
      reason: 'old-generation ACK must not transmit under the new identity',
    );
    expect(node.identity.publicKey, candidate.publicKey);
    expect(node.identityGeneration, 1);
  });

  test('all client key commands make zero radio calls', () async {
    final old = await _seed(10);
    final candidate = await _seed(11);
    final link = FakeDeviceLink(
      devicePrivateKey: (await _seed(12)).meshcore64,
    );
    final persistence = _FakeIdentityPersistence(old);
    final node = MeshNode(
      identity: old,
      link: link,
      identityPersistence: persistence,
    );
    final before = List<String>.of(link.calls);
    await node.exportPrivateKey();
    await node.importPrivateKey(candidate.meshcore64);
    expect(link.calls, before);
    expect(link.exportPrivateKeyRequests, 0);
  });
}

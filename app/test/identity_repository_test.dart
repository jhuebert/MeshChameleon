import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/services/identity_index.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late Map<String, String> values;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mesh_identity_repo_');
    values = <String, String>{};
    FlutterSecureStorage.setMockInitialValues(values);
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  IdentityRepository repository({NodeStoreFactory? factory}) =>
      IdentityRepository(
        supportDirectory: dir,
        secureStore: IdentityStore(),
        nodeStoreFactory: factory,
      );

  test('index_round_trips_and_rejects_duplicate_keys', () async {
    final key = (await LocalIdentity.generate()).publicKey;
    final record = IdentityRecord(
      id: 'a' * 32,
      publicKey: key,
      name: 'Alpha',
      createdAt: 10,
    );
    final index = IdentityIndex(activeId: record.id, identities: [record]);
    final store = IdentityIndexStore(file: File('${dir.path}/index.json'));
    await store.save(index);

    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.activeId, record.id);
    expect(loaded.identities.single.name, 'Alpha');
    expect(loaded.identities.single.publicKey, key);

    final duplicate = IdentityIndex(
      activeId: record.id,
      identities: [
        record,
        IdentityRecord(
          id: 'b' * 32,
          publicKey: key,
          name: 'Beta',
          createdAt: 11,
        ),
      ],
    );
    final raw = File('${dir.path}/index.json');
    await raw.writeAsString(jsonEncode(duplicate.toJson()));
    final backup = File('${raw.path}.bak');
    if (await backup.exists()) await backup.delete();
    expect(
      () => store.load(),
      throwsA(isA<IdentityIndexException>()),
    );
  });

  test('version_1_catalog_migrates_with_identities_enabled', () async {
    final identity = await LocalIdentity.generate();
    final id = 'd' * 32;
    final file = File('${dir.path}/identities/index.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({
      'version': 1,
      'active_id': id,
      'identities': [
        {
          'id': id,
          'public_key': bytesToHex(identity.publicKey),
          'name': 'Old',
          'created_at': 1,
        },
      ],
    }));

    final index = await repository().loadOrCreate();

    expect(index.version, identityIndexVersion);
    expect(index.identities.single.enabled, isTrue);
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(raw['version'], identityIndexVersion);
    final records = raw['identities'] as List<Object?>;
    expect((records.single as Map<String, Object?>)['enabled'], isTrue);
  });

  test('enabled_flag_round_trips_and_active_must_stay_enabled', () async {
    final repo = repository();
    final first = await repo.loadOrCreate();
    final firstId = first.activeId!;
    final second = await repo.create(name: 'Second');
    expect(second.enabled, isTrue);

    final disabled = await repo.setEnabled(second.id, false);
    expect(disabled.enabled, isFalse);
    expect(
      (await repo.loadOrCreate())
          .identities
          .firstWhere((record) => record.id == second.id)
          .enabled,
      isFalse,
    );
    expect(
      () => repo.setEnabled(firstId, false),
      throwsA(isA<IdentityStateException>()),
    );
    expect(
      () => repo.setActive(second.id),
      throwsA(isA<IdentityStateException>()),
    );

    final enabled = await repo.setEnabled(second.id, true);
    expect(enabled.enabled, isTrue);
    await repo.setActive(second.id);
    expect((await repo.loadOrCreate()).activeId, second.id);
  });

  test('disabled_active_selection_is_repaired_to_an_enabled_identity',
      () async {
    final repo = repository();
    final first = await repo.loadOrCreate();
    final firstId = first.activeId!;
    final second = await repo.create(name: 'Second');
    await repo.setEnabled(second.id, false);
    final current = await repo.loadOrCreate();
    await IdentityIndexStore(
      file: File('${dir.path}/identities/index.json'),
    ).save(current.copyWith(activeId: second.id));

    final repaired = await repo.loadOrCreate();

    expect(repaired.activeId, firstId);
    expect(
      repaired.identities.firstWhere((record) => record.id == firstId).enabled,
      isTrue,
    );
  });

  test('index_rejects_non_hex_identity_ids', () async {
    final key = (await LocalIdentity.generate()).publicKey;
    for (final id in ['../escape', '', 'A' * 32, 'a' * 31]) {
      expect(
        IdentityRecord.fromJson({
          'id': id,
          'public_key': bytesToHex(key),
          'name': 'Bad',
          'created_at': 1,
        }),
        isNull,
      );
    }
  });

  test('corrupt_primary_recovers_from_last_good_backup', () async {
    final first = IdentityIndex();
    final file = File('${dir.path}/identities/index.json');
    final store = IdentityIndexStore(file: file);
    await store.save(first);
    final key = (await LocalIdentity.generate()).publicKey;
    final second = IdentityIndex(
      activeId: 'c' * 32,
      identities: [
        IdentityRecord(
          id: 'c' * 32,
          publicKey: key,
          name: 'Backed up',
          createdAt: 12,
        ),
      ],
    );
    await store.save(second);

    // The backup now contains the first (empty) index, the primary the second.
    // Corrupt the primary and verify the backup is used.
    await file.writeAsString('{not json');
    final recovered = await store.load();
    expect(recovered, isNotNull);
    expect(recovered!.identities, isEmpty);
  });

  test('corrupt_primary_and_backup_throws_instead_of_replacing', () async {
    final file = File('${dir.path}/index.json');
    final store = IdentityIndexStore(file: file);
    await file.writeAsString('{');
    await File('${file.path}.bak').writeAsString('{');
    expect(() => store.load(), throwsA(isA<IdentityIndexException>()));
  });

  test('first_run_creates_and_activates_one_default_identity', () async {
    final repo = repository();
    final index = await repo.loadOrCreate();
    expect(index.identities, hasLength(1));
    expect(index.activeId, index.identities.single.id);
    expect(index.identities.single.name, defaultIdentityName);
    expect(index.identities.single.publicKey, hasLength(pubKeySize));
    final key = await repo.loadKey(index.identities.single.id);
    expect(key, isNotNull);
    expect(await repo.loadState(index.identities.single.id), isNotNull);
    expect(values.keys.single, startsWith('meshcore_identity_v2/'));
  });

  test('old_single_identity_key_is_never_read_or_migrated', () async {
    final old = await LocalIdentity.generate();
    values['meshcore_identity_v1'] = bytesToHex(old.meshcore64);
    final repo = repository();
    final index = await repo.loadOrCreate();
    final record = index.identities.single;
    expect(record.publicKey, isNot(old.publicKey));
    expect(values['meshcore_identity_v1'], bytesToHex(old.meshcore64));
    final migrated = await repo.loadKey(record.id);
    expect(migrated, isNotNull);
    expect(migrated!.publicKey, isNot(old.publicKey));
  });

  test('keys_and_state_are_isolated_per_identity', () async {
    final repo = repository();
    await repo.loadOrCreate();
    final second = await repo.create(name: 'Second');
    final first = (await repo.records()).first;
    final firstKey = await repo.loadKey(first.id);
    final secondKey = await repo.loadKey(second.id);
    expect(firstKey!.publicKey, isNot(secondKey!.publicKey));

    await repo.saveState(
      first.id,
      NodeState(prefs: NodePrefs(nodeName: 'One'), queue: [
        QueuedMessage(senderKey: Uint8List(0), text: 'first'),
      ]),
    );
    await repo.saveState(
      second.id,
      NodeState(prefs: NodePrefs(nodeName: 'Two'), queue: [
        QueuedMessage(senderKey: Uint8List(0), text: 'second'),
      ]),
    );
    final firstState = await repo.loadState(first.id);
    final secondState = await repo.loadState(second.id);
    expect(firstState!.queue.single.text, 'first');
    expect(secondState!.queue.single.text, 'second');
    expect(
        repo.stateFile(first.id).path, isNot(repo.stateFile(second.id).path));
  });

  test('additional_identities_are_inactive_with_unique_suggestions', () async {
    final repo = repository();
    final first = await repo.loadOrCreate();
    expect(await repo.suggestName(), 'MeshChameleon 2');
    final second = await repo.create(name: 'Custom');
    expect(second.name, 'Custom');
    expect(await repo.suggestName(), 'MeshChameleon 2');
    final third = await repo.create();
    expect(third.name, 'MeshChameleon 2');
    final after = await repo.records();
    expect(after, hasLength(3));
    final loaded = await repo.loadOrCreate();
    expect(loaded.activeId, first.activeId,
        reason: 'creating identities must not change the active selection');
  });

  test('blank_create_name_falls_back_to_unique_default', () async {
    final repo = repository();
    await repo.loadOrCreate();
    final second = await repo.create(name: '   ');
    expect(second.name, 'MeshChameleon 2');
  });

  test('invalid_name_is_rejected', () async {
    final repo = repository();
    await repo.loadOrCreate();
    expect(
      () => repo.create(name: 'bad\nname'),
      throwsA(isA<IdentityNameException>()),
    );
  });

  test('missing_key_is_reported_without_overwriting_the_record', () async {
    final repo = repository();
    await repo.loadOrCreate();
    final record = (await repo.records()).single;
    values.clear();
    expect(await repo.loadKey(record.id), isNull);
    final again = await repo.loadOrCreate();
    expect(again.identities.single.id, record.id);
  });

  test('duplicate_public_key_update_is_rejected', () async {
    final repo = repository();
    await repo.loadOrCreate();
    final second = await repo.create(name: 'Second');
    final first = (await repo.records()).first;
    final secondKey = (await repo.loadKey(second.id))!.publicKey;
    expect(
      () => repo.updatePublicKey(first.id, secondKey),
      throwsA(isA<IdentityNameException>()),
    );
    final unchanged =
        (await repo.records()).firstWhere((r) => r.id == first.id);
    expect(unchanged.publicKey, isNot(secondKey));
  });

  test('delete_rejects_active_and_last_identity', () async {
    final repo = repository();
    final first = await repo.loadOrCreate();
    final only = first.identities.single;
    expect(
      () => repo.delete(only.id),
      throwsA(isA<IdentityDeleteException>()),
    );
    final second = await repo.create(name: 'Second');
    expect(
      () => repo.delete(only.id),
      throwsA(isA<IdentityDeleteException>()),
    );
    await repo.delete(second.id);
    expect((await repo.records()).single.id, only.id);
    expect(values.keys, hasLength(1));
  });

  test('clear_local_data_preserves_name_and_key_only', () async {
    final repo = repository();
    await repo.loadOrCreate();
    final record = (await repo.records()).single;
    final key = await repo.loadKey(record.id);
    final populated = NodeState(
      prefs: NodePrefs(nodeName: 'Kept Name', pathHashMode: 2),
      contacts: [
        Contact(
          publicKey: (await LocalIdentity.generate()).publicKey,
          name: 'Peer',
        ),
      ],
      channels: {
        0: Channel(
          name: 'Public',
          secret: defaultPublicChannelSecretBytes(),
        ),
        4: Channel(
          name: 'Other',
          secret: Uint8List.fromList(List.filled(16, 3)),
        ),
      },
      queue: [QueuedMessage(senderKey: Uint8List(0), text: 'queued')],
    );
    await repo.saveState(record.id, populated);

    await repo.clearLocalData(record.id);

    final cleared = await repo.loadState(record.id);
    expect(cleared!.prefs.nodeName, 'Kept Name');
    expect(cleared.contacts, isEmpty);
    expect(cleared.channels.keys, [0]);
    expect(cleared.channels[0]!.name, 'Public');
    expect(cleared.queue, isEmpty);
    expect(cleared.prefs.pathHashMode, 0);
    expect((await repo.loadKey(record.id))!.publicKey, key!.publicKey);
  });

  test('no key material is written to the index or node state', () async {
    final repo = repository();
    await repo.loadOrCreate();
    final record = (await repo.records()).single;
    final key = (await repo.loadKey(record.id))!;
    final privateHex = bytesToHex(key.meshcore64);
    final publicHex = bytesToHex(key.publicKey);

    final indexText =
        await File('${dir.path}/identities/index.json').readAsString();
    final stateText = await repo.stateFile(record.id).readAsString();

    expect(indexText, contains(publicHex),
        reason: 'the catalog caches only the public key');
    expect(indexText, isNot(contains(privateHex)));
    expect(stateText, isNot(contains(privateHex)));
    expect(stateText, isNot(contains(publicHex)));
  });

  test('cleanup removes orphan state but preserves another catalog key',
      () async {
    final repo = repository();
    await repo.loadOrCreate();
    final firstRecord = (await repo.records()).single;
    final firstKey = await repo.loadKey(firstRecord.id);
    expect(firstKey, isNotNull);

    final otherDir =
        await Directory.systemTemp.createTemp('mesh_identity_other_');
    addTearDown(() => otherDir.delete(recursive: true));
    final other = IdentityRepository(
      supportDirectory: otherDir,
      secureStore: IdentityStore(),
    );
    await other.loadOrCreate();
    final orphan = Directory('${other.identitiesDirectory.path}/orphan');
    await orphan.create(recursive: true);
    await File('${orphan.path}/node_state.json').writeAsString('{}');

    await other.cleanupOrphans();

    expect(await orphan.exists(), isFalse);
    final kept = await other.loadKey(firstRecord.id);
    expect(kept, isNotNull,
        reason: 'the shared Linux keyring must not be pruned by a second '
            'support directory');
    expect(kept!.publicKey, firstKey!.publicKey);
  });

  test('first_run_key_write_failure_does_not_create_a_catalog', () async {
    final repo = IdentityRepository(
      supportDirectory: dir,
      secureStore: _FailingIdentityStore(),
    );
    await expectLater(
      repo.loadOrCreate(),
      throwsA(isA<FileSystemException>()),
    );
    expect(await File('${dir.path}/identities/index.json').exists(), isFalse);
  });

  test('corrupt_state_is_quarantined_and_defaults_are_used', () async {
    final repo = repository();
    await repo.loadOrCreate();
    final record = (await repo.records()).single;
    final file = repo.stateFile(record.id);
    await file.parent.create(recursive: true);
    await file.writeAsString('{broken');
    expect(await repo.loadState(record.id), isNull);
    expect(await file.exists(), isFalse);
    final quarantined = file.parent
        .list()
        .where((e) => e.path.contains('node_state.json.corrupt-'));
    expect(await quarantined.length, 1);
    final fresh =
        await repo.loadState(record.id) ?? defaultNodeState(record.name);
    expect(fresh.prefs.nodeName, record.name);
  });
}

class _FailingIdentityStore extends IdentityStore {
  @override
  Future<void> saveById(String id, LocalIdentity identity) async {
    throw const FileSystemException('secure key write failed');
  }
}

Uint8List defaultPublicChannelSecretBytes() =>
    Uint8List.fromList(LocalIdentity.defaultPublicChannelSecret);

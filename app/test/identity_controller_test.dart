import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/session_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('import_valid_seed_expanded_key_survives_secure_store_restart',
      () async {
    final values = <String, String>{};
    FlutterSecureStorage.setMockInitialValues(values);
    final seed = Uint8List(32)..[0] = 41;
    final seeded = await LocalIdentity.fromSeed(seed);
    final store = IdentityStore();
    await store.save(seeded);
    expect(values.values.single, bytesToHex(seeded.meshcore64));
    expect(values.values.single.length, 128,
        reason: 'secure storage holds the expanded 64-byte key, not the seed');

    final restarted = IdentityStore();
    final loaded = await restarted.load();
    expect(loaded, isNotNull);
    expect(loaded!.publicKey, seeded.publicKey);
    expect(loaded.meshcore64, seeded.meshcore64);
    expect(await LocalIdentity.validateMeshcore64(loaded.meshcore64), isTrue);
  });

  test('app_import_while_node_running_changes_node_not_only_ui', () async {
    final values = <String, String>{};
    FlutterSecureStorage.setMockInitialValues(values);
    final dir = await Directory.systemTemp.createTemp('mesh_app_identity_');
    addTearDown(() => dir.delete(recursive: true));
    final store = IdentityStore();
    final old = await LocalIdentity.generate();
    await store.save(old);
    final app = AppState(
      store: store,
      nodeStore: InMemoryNodeStore(),
      sessionStore: SessionStore(file: File('${dir.path}/session.json')),
      capabilities: const DeviceCapabilities(
        supportsBle: false,
        supportsSimulatedCompanion: true,
      ),
    );
    app.identity = old;
    await app.connectSimulated();
    addTearDown(app.disconnectDevice);
    expect(app.node, isNotNull, reason: app.logs.join('\n'));
    expect(app.node!.identity.publicKey, old.publicKey);

    final seed = Uint8List(32)..[0] = 42;
    final imported = await LocalIdentity.fromSeed(seed);
    await app.importIdentity(seed);

    expect(app.deviceConnected, isTrue);
    expect(app.node, isNotNull);
    expect(app.node!.identity.publicKey, imported.publicKey);
    expect(app.identity!.publicKey, imported.publicKey,
        reason: 'UI state and running node agree on the active key');
    expect(app.node!.identityGeneration, 1);
    expect(values.values.single, bytesToHex(imported.meshcore64));
    expect(await app.exportIdentity(), imported.meshcore64);
    final logs = app.logs.join('\n');
    expect(logs, isNot(contains(bytesToHex(old.meshcore64))));
    expect(logs, isNot(contains(bytesToHex(imported.meshcore64))));
    expect(logs, isNot(contains(bytesToHex(imported.publicKey))));
  });
}

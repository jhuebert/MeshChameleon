// Linux secure-storage smoke test (no radio, no UI).
//
//   flutter test integration_test/secure_storage_smoke_test.dart -d linux
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/services/identity_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real platform secure storage round-trips one identity key',
      (tester) async {
    final store = IdentityStore(
      storage: const FlutterSecureStorage(
        aOptions: AndroidOptions(
          resetOnError: false,
          migrateWithBackup: true,
        ),
      ),
    );
    final id = bytesToHex(Uint8List.fromList(List<int>.filled(16, 0x5a)));
    final identity = await LocalIdentity.generate();
    addTearDown(() async {
      try {
        await store.deleteById(id);
      } catch (_) {}
    });

    await store.saveById(id, identity);
    expect(await store.hasById(id), isTrue);
    final loaded = await store.loadById(id);
    expect(loaded, isNotNull);
    expect(bytesToHex(loaded!.meshcore64), bytesToHex(identity.meshcore64));
  });
}

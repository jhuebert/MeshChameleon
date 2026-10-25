import 'dart:io';
import 'dart:typed_data';

import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

Future<LocalIdentity> _seed(int value) =>
    LocalIdentity.fromSeed(Uint8List(32)..[0] = value);

void main() {
  test('headless_temp_key_permissions_are_private_before_secret_write',
      () async {
    final dir = await Directory.systemTemp.createTemp('mesh_identity_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/identity.hex');
    final identity = await _seed(1);
    var hookRan = false;
    final persistence = FileIdentityPersistence(
      file,
      onTempPrepared: (temp) {
        hookRan = true;
        expect(temp.existsSync(), isTrue);
        expect(temp.lengthSync(), 0, reason: 'no secret before permissions');
        if (!Platform.isWindows) {
          expect(temp.statSync().mode & 0x1FF, 0x180);
        }
      },
    );

    await persistence.save(identity);
    expect(hookRan, isTrue);
    if (!Platform.isWindows) {
      expect(file.statSync().mode & 0x1FF, 0x180);
    }
    expect(await file.readAsString(), bytesToHex(identity.meshcore64));
    final loaded = await persistence.load();
    expect(loaded?.publicKey, identity.publicKey);
  });

  test('headless_file_is_atomic0600_and_loads_after_replace', () async {
    final dir = await Directory.systemTemp.createTemp('mesh_identity_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/identity.hex');
    final first = await _seed(2);
    final second = await _seed(3);
    final persistence = FileIdentityPersistence(file);

    await persistence.save(first);
    await persistence.save(second);
    if (!Platform.isWindows) {
      expect(file.statSync().mode & 0x1FF, 0x180);
    }
    expect(await file.readAsString(), bytesToHex(second.meshcore64));
    final leftovers =
        await dir.list().where((e) => e.path.contains('.tmp-')).toList();
    expect(leftovers, isEmpty);
    expect((await persistence.load())?.publicKey, second.publicKey);
  });

  test('ephemeral_import_lasts_until_exit', () async {
    final identity = await _seed(4);
    final persistence = MemoryIdentityPersistence();
    expect(await persistence.load(), isNull);
    await persistence.save(identity);
    expect((await persistence.load())?.meshcore64, identity.meshcore64);
  });
}

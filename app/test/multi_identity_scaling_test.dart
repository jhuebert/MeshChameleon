// Eight live identities with local DM fan-out and no drops.
import 'dart:io';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/network_connection_store.dart';
import 'package:meshchameleon/services/session_store.dart';

void main() {
  test('eight identities live and a local DM mirrors without drops', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('mesh_scale_');
    final app = AppState(
      repository: IdentityRepository(
        supportDirectory: dir,
        secureStore: IdentityStore(),
      ),
      sessionStore: SessionStore(file: File('${dir.path}/session.json')),
      networkConnectionStore:
          NetworkConnectionStore(file: File('${dir.path}/history.json')),
      capabilities: const DeviceCapabilities(
        supportsBle: false,
        supportsSimulatedCompanion: true,
      ),
    );
    addTearDown(() async {
      await app.disconnectDevice();
      await app.manager?.dispose();
      await dir.delete(recursive: true);
    });
    await app.loadIdentities();
    for (var i = 2; i <= 8; i++) {
      expect(await app.createIdentity(name: 'Scale $i'), isNotNull);
    }
    expect(app.identities.length, 8);

    final bus = FakeRadioBus();
    final link = FakeDeviceLink(
      bus: bus,
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    await link.connect();
    expect(await app.connectSimulated(simulatedLink: link), isTrue);
    expect(app.manager!.runtimes.where((r) => r.live).length, 8);

    final source = app.manager!.runtimes
        .firstWhere((r) => r.record.name == 'MeshChameleon');
    final target =
        app.manager!.runtimes.firstWhere((r) => r.record.name == 'Scale 2');
    await source.node!.addUpdateContact(Contact(
      publicKey: Uint8List.fromList(target.identity!.publicKey),
      name: 'Scale 2',
      outPathLen: 0,
      outPath: Uint8List(0),
    ));
    await target.node!.addUpdateContact(Contact(
      publicKey: Uint8List.fromList(source.identity!.publicKey),
      name: 'MeshChameleon',
      outPathLen: 0,
      outPath: Uint8List(0),
    ));
    for (var i = 0; i < 20; i++) {
      final result = await source.node!
          .sendTextMessage(target.identity!.publicKey, 'scale $i');
      expect(result.success, isTrue);
    }
    expect(target.node!.queuedDirectCount, 20);
  });
}

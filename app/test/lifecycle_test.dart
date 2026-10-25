import 'dart:io';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/session_store.dart';

const _capabilities = DeviceCapabilities(
  supportsBle: false,
  supportsSimulatedCompanion: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late IdentityRepository repository;
  late SessionStore sessionStore;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('mesh_lifecycle_');
    repository = IdentityRepository(
      supportDirectory: dir,
      secureStore: IdentityStore(),
    );
    sessionStore = SessionStore(file: File('${dir.path}/session.json'));
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  Future<AppState> newApp() async {
    final app = AppState(
      repository: repository,
      sessionStore: sessionStore,
      capabilities: _capabilities,
      reconnectDelay: const Duration(milliseconds: 10),
    );
    await app.loadIdentities();
    return app;
  }

  test('shutdown suppresses reconnect and auto-resume until explicit connect',
      () async {
    final app = await newApp();
    addTearDown(app.disconnectDevice);
    app.autoResume = true;
    final link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
      deviceNodeName: 'Physical companion',
    );
    await app.connectSimulated(simulatedLink: link);
    expect(app.node, isNotNull, reason: app.logs.join('\n'));
    expect(app.intentionallyOff, isFalse);

    await app.node!.shutdown();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(link.shutdownRequests, 1);
    expect(app.intentionallyOff, isTrue);
    expect(app.deviceConnected, isFalse);
    expect(app.manager!.runtimes, isEmpty);
    final saved = await sessionStore.load();
    expect(saved, isNotNull);
    expect(saved!.intentionallyOff, isTrue);

    // Wait past the injected reconnect delay: the intentional-off state must
    // still suppress the watcher.
    final connectsAfterShutdown =
        link.calls.where((c) => c == 'connect').length;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(
        link.calls.where((c) => c == 'connect').length, connectsAfterShutdown);

    final resumed = await newApp();
    addTearDown(resumed.disconnectDevice);
    expect(resumed.identities, isNotEmpty);
    expect(resumed.autoResume, isTrue);
    expect(resumed.deviceConnected, isFalse);
    expect(resumed.logs.join('\n'), contains('intentional shutdown'));

    // An explicit connect clears the intentional-off state.
    final secondLink = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    await app.connectSimulated(simulatedLink: secondLink);
    expect(app.intentionallyOff, isFalse);
    expect(app.deviceConnected, isTrue);
    final cleared = await sessionStore.load();
    expect(cleared!.intentionallyOff, isFalse);
  });

  test('reboot reconnects with every virtual identity and prefs intact',
      () async {
    final app = await newApp();
    addTearDown(app.disconnectDevice);
    await app.createIdentity(name: 'Second');
    final link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
      rebootDisconnects: true,
    );
    await app.connectSimulated(simulatedLink: link);
    final node = app.node!;
    await node.setAdvertName('Reboot Safe');
    await node.setPathHashMode(2);
    await node.setMultiAcks(3);
    await node.setTimezoneOffsetHours(-4);
    final identityBefore = Uint8List.fromList(node.identity.publicKey);

    await node.reboot();
    expect(link.rebootRequests, 1);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(app.deviceConnected, isTrue);
    expect(app.node, same(node));
    expect(app.node!.identity.publicKey, identityBefore);
    expect(app.node!.prefs.nodeName, 'Reboot Safe');
    expect(app.node!.prefs.pathHashMode, 2);
    expect(app.node!.prefs.multiAcks, 3);
    expect(app.node!.prefs.timezoneOffsetHours, -4);
    expect(app.manager!.runtimes, hasLength(2));
    expect(link.calls.where((c) => c == 'connect').length,
        greaterThanOrEqualTo(2));
  });
}

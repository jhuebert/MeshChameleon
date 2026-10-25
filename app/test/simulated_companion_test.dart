import 'dart:io';

import 'package:device_link/device_link.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/network_connection_store.dart';
import 'package:meshchameleon/services/session_store.dart';

const _capabilities = DeviceCapabilities(
  supportsBle: false,
  supportsSimulatedCompanion: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late IdentityRepository repository;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('meshchameleon_sim_');
    repository = IdentityRepository(
      supportDirectory: dir,
      secureStore: IdentityStore(),
    );
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  Future<AppState> newApp() async {
    final app = AppState(
      repository: repository,
      sessionStore: SessionStore(file: File('${dir.path}/session.json')),
      networkConnectionStore: NetworkConnectionStore(
        file: File('${dir.path}/network_connections.json'),
      ),
      capabilities: _capabilities,
    );
    await app.loadIdentities();
    return app;
  }

  test('simulated companion starts every identity and serves the proxy',
      () async {
    final app = await newApp();
    await app.connectSimulated();
    addTearDown(app.disconnectDevice);

    expect(app.deviceConnected, isTrue, reason: app.logs.join('\n'));
    expect(app.deviceLabel, 'Simulated companion');
    expect(app.node, isNotNull);
    expect(app.manager!.runtimes, hasLength(1));

    await app.startProxy(serverPort: 0);
    expect(app.proxyStatus, ProxyStatus.running);
    expect(app.port, greaterThan(0));
  });

  test('attach_does_not_write_device_settings', () async {
    final link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
      deviceNodeName: 'Physical companion',
    );
    final app = await newApp();
    await app.connectSimulated(simulatedLink: link);
    addTearDown(app.disconnectDevice);

    expect(app.node, isNotNull, reason: app.logs.join('\n'));
    // Attach performs the handshake, one tuning read, registers the shared RX
    // listener, and reads a battery sample. It never changes a physical setting.
    expect(
        link.calls,
        containsAllInOrder([
          'connect',
          'deviceInfo',
          'selfInfo',
          'tuningParams',
          'setRawRxListener',
        ]));
    const writes = [
      'sendRawPacket',
      'setRadioParams',
      'setTxPower',
      'reboot',
      'setTuningParams',
      'setPathHashMode',
      'runCliCommand',
    ];
    expect(link.calls.where(writes.contains), isEmpty);
  });

  test('fresh_name_is_virtual_existing_name_preserved', () async {
    final freshApp = await newApp();
    await freshApp.connectSimulated(
      simulatedLink: FakeDeviceLink(
        deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
        deviceNodeName: 'Physical companion',
      ),
    );
    addTearDown(freshApp.disconnectDevice);
    expect(freshApp.node!.prefs.nodeName, 'MeshChameleon');
    expect(freshApp.node!.prefs.nodeName, isNot('Physical companion'));
    await freshApp.disconnectDevice();

    final id = freshApp.identities.single.id;
    await repository.saveState(
      id,
      NodeState(prefs: NodePrefs(nodeName: 'My Virtual Node')),
    );
    final existingApp = await newApp();
    await existingApp.connectSimulated(
      simulatedLink: FakeDeviceLink(
        deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
        deviceNodeName: 'Physical companion',
      ),
    );
    addTearDown(existingApp.disconnectDevice);
    expect(existingApp.node!.prefs.nodeName, 'My Virtual Node');
  });

  test('physical_max_tx_and_signed_tx_are_adopted', () async {
    final link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 13, clientRepeat: 1),
      radioParams_: const RadioParams(
        frequencyHz: 915000000,
        bandwidthHz: 250000,
        spreadingFactor: 10,
        codingRate: 5,
        txPowerDbm: -3,
      ),
      maxTxPower: 17,
    );
    final app = await newApp();
    await app.connectSimulated(simulatedLink: link);
    addTearDown(app.disconnectDevice);

    expect(app.node!.physical.firmwareVerCode, 13);
    expect(app.node!.physical.maxTxPower, 17);
    expect(app.node!.prefs.maxTxPower, 17);
    expect(app.node!.prefs.txPowerDbm, -3);
    expect(app.node!.getDeviceInfo().firmwareVerCode, targetFirmwareVerCode);
    expect(app.node!.getDeviceInfo().version, targetCompatibilityVersion);
    expect(app.node!.getDeviceInfo().maxContacts, virtualMaxContacts);
    expect(app.node!.getDeviceInfo().maxChannels, virtualMaxChannels);
    expect(app.node!.getDeviceInfo().clientRepeat, 1);
  });

  test('simulated companion is refused in release-shaped capabilities',
      () async {
    final app = AppState(
      repository: repository,
      sessionStore: SessionStore(file: File('${dir.path}/session.json')),
      networkConnectionStore: NetworkConnectionStore(
        file: File('${dir.path}/network_connections.json'),
      ),
      capabilities: const DeviceCapabilities(
        supportsBle: false,
        supportsSimulatedCompanion: false,
      ),
    );
    await app.loadIdentities();

    await app.connectSimulated();

    expect(app.deviceConnected, isFalse);
    expect(app.node, isNull);
    expect(app.logs.last, contains('development builds'));
  });
}

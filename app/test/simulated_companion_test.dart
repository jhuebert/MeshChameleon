import 'dart:io';

import 'package:device_link/device_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/session_store.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('meshchameleon_sim_');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  AppState newApp({NodeStore? nodeStore}) => AppState(
        nodeStore: nodeStore ?? InMemoryNodeStore(),
        sessionStore: SessionStore(file: File('${dir.path}/session.json')),
        capabilities: const DeviceCapabilities(
          supportsBle: false,
          supportsSimulatedCompanion: true,
        ),
      );

  test('simulated companion starts the node and serves the proxy', () async {
    final app = AppState(
      nodeStore: InMemoryNodeStore(),
      sessionStore: SessionStore(file: File('${dir.path}/session.json')),
      capabilities: const DeviceCapabilities(
        supportsBle: false,
        supportsSimulatedCompanion: true,
      ),
    );
    app.identity = await LocalIdentity.generate();

    await app.connectSimulated();
    addTearDown(app.disconnectDevice);

    expect(app.deviceConnected, isTrue, reason: app.logs.join('\n'));
    expect(app.deviceLabel, 'Simulated companion');
    expect(app.node, isNotNull);

    await app.startProxy(serverPort: 0);
    expect(app.proxyStatus, ProxyStatus.running);
    expect(app.port, greaterThan(0));
  });

  test('attach_does_not_write_device_settings', () async {
    final link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
      deviceNodeName: 'Physical companion',
    );
    final app = newApp();
    app.identity = await LocalIdentity.generate();

    await app.connectSimulated(simulatedLink: link);
    addTearDown(app.disconnectDevice);

    expect(app.node, isNotNull, reason: app.logs.join('\n'));
    // Attach only performs the handshake, registers the RX listener, and reads
    // a battery sample. It never changes a physical setting.
    expect(link.calls, [
      'connect',
      'deviceInfo',
      'selfInfo',
      'setRawRxListener',
      'battery',
    ]);
    const writes = [
      'sendRawPacket',
      'setRadioParams',
      'setTxPower',
      'reboot',
      'setTuningParams',
      'setPathHashMode',
      'runCliCommand',
      'exportPrivateKey',
    ];
    expect(link.calls.where(writes.contains), isEmpty);
  });

  test('fresh_name_is_virtual_existing_name_preserved', () async {
    final freshApp = newApp();
    freshApp.identity = await LocalIdentity.generate();
    await freshApp.connectSimulated(
      simulatedLink: FakeDeviceLink(
        deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
        deviceNodeName: 'Physical companion',
      ),
    );
    addTearDown(freshApp.disconnectDevice);
    expect(freshApp.node!.prefs.nodeName, 'MeshChameleon');
    expect(freshApp.node!.prefs.nodeName, isNot('Physical companion'));

    final store = InMemoryNodeStore();
    await store.save(NodeState(prefs: NodePrefs(nodeName: 'My Virtual Node')));
    final existingApp = newApp(nodeStore: store);
    existingApp.identity = await LocalIdentity.generate();
    await existingApp.connectSimulated(
      simulatedLink: FakeDeviceLink(
        deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
        deviceNodeName: 'Physical companion',
      ),
    );
    addTearDown(existingApp.disconnectDevice);
    expect(existingApp.node!.prefs.nodeName, 'My Virtual Node');

    // A name persisted by an older build (including the old default) is also
    // user state and is not replaced by the physical device's name.
    final legacyStore = InMemoryNodeStore();
    await legacyStore
        .save(NodeState(prefs: NodePrefs(nodeName: 'MeshCore Proxy')));
    final legacyApp = newApp(nodeStore: legacyStore);
    legacyApp.identity = await LocalIdentity.generate();
    await legacyApp.connectSimulated(
      simulatedLink: FakeDeviceLink(
        deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
        deviceNodeName: 'Physical companion',
      ),
    );
    addTearDown(legacyApp.disconnectDevice);
    expect(legacyApp.node!.prefs.nodeName, 'MeshCore Proxy');
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
    final app = newApp();
    app.identity = await LocalIdentity.generate();
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
      nodeStore: InMemoryNodeStore(),
      sessionStore: SessionStore(file: File('${dir.path}/session.json')),
      capabilities: const DeviceCapabilities(
        supportsBle: false,
        supportsSimulatedCompanion: false,
      ),
    );

    await app.connectSimulated();

    expect(app.deviceConnected, isFalse);
    expect(app.node, isNull);
    expect(app.logs.last, contains('development builds'));
  });
}

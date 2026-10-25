import 'dart:io';

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

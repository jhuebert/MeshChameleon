import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/services/session_store.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

void main() {
  test('SessionConfig survives a JSON round-trip', () {
    const config = SessionConfig(
      kind: DeviceTargetKind.ble,
      bleRemoteId: 'AA:BB:CC:DD:EE:FF',
      bleName: 'MeshCore-1234',
      proxyPort: 5100,
      autoResume: true,
      intentionallyOff: true,
    );
    expect(config.toJson()['version'], sessionConfigVersion);
    final restored = SessionConfig.fromJson(config.toJson());
    expect(restored, isNotNull);
    expect(restored!.kind, DeviceTargetKind.ble);
    expect(restored.bleRemoteId, 'AA:BB:CC:DD:EE:FF');
    expect(restored.bleName, 'MeshCore-1234');
    expect(restored.proxyPort, 5100);
    expect(restored.autoResume, isTrue);
    expect(restored.intentionallyOff, isTrue);
    expect(restored.copyWith(proxyPort: 5200).intentionallyOff, isTrue);
  });

  test('SessionConfig defaults ports when absent', () {
    final restored =
        SessionConfig.fromJson({'kind': 'tcp', 'host': '10.0.0.5'});
    expect(restored, isNotNull);
    expect(restored!.devicePort, defaultCompanionPort);
    expect(restored.proxyPort, defaultCompanionPort);
    expect(restored.autoResume, isFalse);
    expect(restored.intentionallyOff, isFalse);
  });

  test('SessionConfig.fromJson rejects an unknown kind', () {
    expect(SessionConfig.fromJson({'kind': 'carrier-pigeon'}), isNull);
  });

  test('SessionConfig.fromJson treats a versionless file as version 1', () {
    final restored = SessionConfig.fromJson(
        {'kind': 'tcp', 'host': '10.0.0.5', 'proxyPort': 5200});
    expect(restored, isNotNull);
    expect(restored!.proxyPort, 5200);
  });

  test('SessionConfig.fromJson rejects an unsupported version', () {
    expect(
      SessionConfig.fromJson(
          {'version': sessionConfigVersion + 1, 'kind': 'tcp'}),
      isNull,
    );
  });

  test('SessionStore round-trips through a file', () async {
    final dir = await Directory.systemTemp.createTemp('meshchameleon_session');
    addTearDown(() => dir.delete(recursive: true));
    final store = SessionStore(file: File('${dir.path}/session.json'));

    expect(await store.load(), isNull);

    const config = SessionConfig(
      kind: DeviceTargetKind.tcp,
      host: '192.168.1.55',
      devicePort: 5000,
      proxyPort: 5200,
      autoResume: true,
    );
    await store.save(config);

    final restored = await store.load();
    expect(restored, isNotNull);
    expect(restored!.kind, DeviceTargetKind.tcp);
    expect(restored.host, '192.168.1.55');
    expect(restored.proxyPort, 5200);
  });

  test('SessionStore ignores a corrupt file', () async {
    final dir = await Directory.systemTemp.createTemp('meshchameleon_bad');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/session.json');
    await file.writeAsString('{ not json');
    expect(await SessionStore(file: file).load(), isNull);
  });
}

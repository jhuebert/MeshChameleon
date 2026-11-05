import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/services/json_document_store.dart';
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
      recoveryPending: true,
      recoveryServeProxy: true,
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
    expect(restored.recoveryPending, isTrue);
    expect(restored.recoveryServeProxy, isTrue);
    final updated = restored.copyWith(proxyPort: 5200);
    expect(updated.intentionallyOff, isTrue);
    expect(updated.recoveryPending, isTrue);
    expect(updated.recoveryServeProxy, isTrue);
  });

  test('a version 1 session reads the recovery flags as false', () {
    final restored = SessionConfig.fromJson({
      'version': 1,
      'kind': 'tcp',
      'host': '10.0.0.5',
      'proxyPort': 5200,
    });
    expect(restored, isNotNull);
    expect(restored!.proxyPort, 5200);
    expect(restored.recoveryPending, isFalse);
    expect(restored.recoveryServeProxy, isFalse);
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

  test('SessionConfig.fromJson rejects invalid and fractional ports', () {
    for (final json in <Map<String, dynamic>>[
      {'kind': 'tcp', 'host': '10.0.0.5', 'devicePort': 0},
      {'kind': 'tcp', 'host': '10.0.0.5', 'devicePort': 70000},
      {'kind': 'tcp', 'host': '10.0.0.5', 'devicePort': 5000.5},
      {'kind': 'tcp', 'host': '10.0.0.5', 'proxyPort': -1},
      {'kind': 'tcp', 'host': '10.0.0.5', 'proxyPort': 70000},
      {'kind': 'tcp', 'host': '10.0.0.5', 'proxyPort': 5000.5},
    ]) {
      expect(SessionConfig.fromJson(json), isNull, reason: '$json');
    }
    expect(
      SessionConfig.fromJson(
        {'kind': 'tcp', 'host': '10.0.0.5', 'proxyPort': 0},
      )?.proxyPort,
      0,
      reason: 'zero is valid and selects an ephemeral proxy port',
    );
  });

  test('SessionConfig.fromJson rejects wrong field types without throwing', () {
    for (final json in <Map<String, dynamic>>[
      {'kind': 'tcp', 'host': 42},
      {'kind': 'ble', 'bleRemoteId': 42},
      {'kind': 'ble', 'bleName': 42},
      {'kind': 'tcp', 'autoResume': 'yes'},
      {'kind': 'tcp', 'intentionallyOff': 1},
      {'kind': 'tcp', 'recoveryPending': 'yes'},
      {'kind': 'tcp', 'recoveryServeProxy': 1},
    ]) {
      expect(SessionConfig.fromJson(json), isNull, reason: '$json');
    }
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

  test('SessionStore quarantines a corrupt file and throws', () async {
    final dir = await Directory.systemTemp.createTemp('meshchameleon_bad');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/session.json');
    await file.writeAsString('{ not json');

    await expectLater(
      SessionStore(file: file).load(),
      throwsA(isA<JsonDocumentException>()
          .having((e) => e.failure, 'failure', JsonDocumentFailure.corrupt)
          .having((e) => e.quarantinePath, 'quarantinePath', isNotNull)),
    );
    expect(await file.exists(), isFalse);
  });

  test('SessionStore rejects a future version before decoding', () async {
    final dir = await Directory.systemTemp.createTemp('meshchameleon_future');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/session.json');
    await file.writeAsString(jsonEncode({
      'version': sessionConfigVersion + 1,
      'kind': 'tcp',
    }));

    await expectLater(
      SessionStore(file: file).load(),
      throwsA(isA<JsonDocumentVersionException>()
          .having((e) => e.version, 'version', sessionConfigVersion + 1)),
    );
    expect(await file.exists(), isFalse);
  });
}

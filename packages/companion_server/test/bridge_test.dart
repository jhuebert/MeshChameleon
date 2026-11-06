import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  late CompanionBridge bridge;

  setUp(() => bridge = CompanionBridge());

  final unsupported = throwsA(
    isA<CompanionOperationError>()
        .having((e) => e.code, 'code', errCodeUnsupportedCmd),
  );

  test('the bridge exposes every capability interface', () {
    expect(bridge, isA<ContactHost>());
    expect(bridge, isA<MessageHost>());
    expect(bridge, isA<RadioConfigHost>());
    expect(bridge, isA<IdentityHost>());
    expect(bridge, isA<CompanionCliHost>());
    expect(bridge, isA<StatsHost>());
    expect(bridge, isA<LifecycleHost>());
  });

  test('the default contact host is empty', () {
    expect(bridge.getContacts(), isEmpty);
    expect(bridge.contactCount, 0);
    expect(bridge.getContactByKey(Uint8List(32)), isNull);
  });

  test('push sink can be attached and cleared', () {
    expect(bridge.pushSink, isNull);
    final sink = NoopCompanionPushSink();
    bridge.setPushSink(sink);
    expect(bridge.pushSink, same(sink));
    bridge.setPushSink(null);
    expect(bridge.pushSink, isNull);
  });

  test('the no-op push sink accepts every push', () {
    final sink = NoopCompanionPushSink();
    final key = Uint8List(32);
    final prefix = Uint8List(6);
    sink.pushMsgWaiting();
    sink.pushSendConfirmed(1, tripTimeMs: 2);
    sink.pushAdvert(key);
    sink.pushNewAdvert(key);
    sink.pushContactDeleted(key);
    sink.pushContactsFull();
    sink.pushPathUpdated(key);
    sink.pushTelemetryResponse(prefix, Uint8List(1));
    sink.pushBinaryResponse(1, Uint8List(1));
    sink.pushRawRxData(6, -70, Uint8List(1));
    sink.pushRawData(6, -70, Uint8List(1));
    sink.pushControlData(6, -70, 1, Uint8List(1));
    sink.pushPathDiscoveryResponse(
      prefix,
      1,
      Uint8List(1),
      1,
      Uint8List(1),
    );
    sink.pushLoginSuccess(prefix);
    sink.pushLoginFail(prefix);
    sink.pushStatusResponse(prefix, Uint8List(1));
    sink.pushTraceData(1, 0, 1, 2, Uint8List(1), Uint8List(1), 24);
  });

  test('local information defaults describe an empty peer', () {
    final prefs = bridge.getSelfInfo();
    expect(prefs.nodeName, 'MeshChameleon');
    expect(prefs.frequencyHz, 915000000);

    expect(bridge.getDeviceInfo().manufacturer, 'MeshChameleon');
    expect(bridge.maxChannels, 8);
    expect(bridge.getPathHashMode(), bridge.getDeviceInfo().pathHashMode);
    expect(bridge.getTime(), isNonZero);

    expect(bridge.getContacts(), isEmpty);
    expect(bridge.getContactByKey(Uint8List(32)), isNull);
    expect(bridge.getPersistentContactByKey(Uint8List(32)), isNull);
    expect(bridge.getContactByKeyPrefix(Uint8List(6)), isNull);
    expect(bridge.getChannel(0), isNull);
    expect(bridge.getAdvertPath(Uint8List(7)), isNull);
    expect(bridge.getCustomVars(), isEmpty);
    expect(bridge.getAutoAddConfig(), 0);
    expect(bridge.getAutoAddMaxHops(), 0);
    expect(bridge.getDefaultFloodScope(), ('', null));
    expect(bridge.lifecycleGeneration, 0);
    expect(bridge.logout(Uint8List(32)), isFalse);
    expect(bridge.hasConnection(Uint8List(32)), isFalse);
  });

  test('identity and battery operations fail instead of returning defaults',
      () async {
    expect(() => bridge.getPublicKey(), unsupported);
    expect(() => bridge.setTime(1234), unsupported);
    await expectLater(bridge.exportPrivateKey(), unsupported);
    await expectLater(bridge.importPrivateKey(Uint8List(64)), unsupported);
    expect(() => bridge.sign(Uint8List(0)), unsupported);
    await expectLater(bridge.getBatteryAndStorage(), unsupported);
    await expectLater(bridge.getTuningParams(), unsupported);
    await expectLater(bridge.getStats(statsTypeCore), unsupported);
  });

  test('every unimplemented write fails with CompanionOperationError',
      () async {
    final empty = Uint8List(32);
    await expectLater(
      bridge.addUpdateContact(Contact(publicKey: empty)),
      unsupported,
    );
    await expectLater(bridge.removeContact(empty), unsupported);
    await expectLater(bridge.resetPath(empty), unsupported);
    await expectLater(bridge.setChannel(0, 'name', Uint8List(16)), unsupported);
    await expectLater(bridge.setAdvertName('name'), unsupported);
    await expectLater(bridge.setAdvertLatLon(1, 2), unsupported);
    await expectLater(bridge.setRadioParams(1, 2, 3, 4), unsupported);
    await expectLater(bridge.setTxPower(10), unsupported);
    await expectLater(bridge.setPathHashMode(1), unsupported);
    await expectLater(bridge.setTuningParams(1, 2), unsupported);
    await expectLater(bridge.setAutoAddConfig(1, 2), unsupported);
    await expectLater(
      bridge.setOtherParams(manualAddContacts: 1),
      unsupported,
    );
    await expectLater(
      bridge.setDefaultFloodScope('scope', Uint8List(16)),
      unsupported,
    );
    await expectLater(bridge.reboot(), unsupported);
    expect(() => bridge.setFloodScopeKey(Uint8List(16)), unsupported);
    expect(bridge.setFloodUnscoped, unsupported);
  });

  test('every unimplemented send fails with CompanionOperationError', () async {
    final empty = Uint8List(32);
    await expectLater(bridge.sendTextMessage(empty, 'hi'), unsupported);
    await expectLater(bridge.sendChannelMessage(0, 'hi'), unsupported);
    await expectLater(
      bridge.sendChannelData(0, 1, Uint8List(1)),
      unsupported,
    );
    await expectLater(bridge.advertise(), unsupported);
    await expectLater(bridge.importContact(Uint8List(1)), unsupported);
    await expectLater(bridge.shareContact(empty), unsupported);
    await expectLater(
      bridge.sendRawData(Uint8List(4), Uint8List(0), 0),
      unsupported,
    );
    await expectLater(bridge.sendRawPacket(Packet(), 0), unsupported);
    await expectLater(bridge.sendBinaryReq(empty, Uint8List(1)), unsupported);
    await expectLater(bridge.sendAnonReq(empty, Uint8List(1)), unsupported);
    await expectLater(bridge.sendTelemetryRequest(empty), unsupported);
    await expectLater(
      bridge.sendTracePathRaw(1, 2, 0, Uint8List(0)),
      unsupported,
    );
    await expectLater(bridge.sendPathDiscoveryReq(empty), unsupported);
    await expectLater(bridge.sendLogin(empty, 'pw'), unsupported);
    await expectLater(bridge.sendStatusReq(empty), unsupported);
    await expectLater(bridge.sendControlData(Uint8List(1)), unsupported);
  });

  test('empty-state queries stay quiet', () async {
    expect(await bridge.runCliCommand('ver'), isNull);
    expect(await bridge.getAllowedRepeatFreq(), isEmpty);
    expect(await bridge.exportContact(null), isNull);
    expect(await bridge.syncNextMessage(), isNull);
  });

  test('setCustomVar rejects unknown variables', () async {
    await expectLater(
      bridge.setCustomVar('x', 'y'),
      throwsA(isA<CompanionOperationError>()),
    );
  });

  test('runCliCommandBytes trims one trailing NUL and decodes text', () async {
    final bridge = _CliBridge();
    expect(await bridge.runCliCommandBytes(_ascii('ver')), 'CLI: ver');
    expect(
      await bridge
          .runCliCommandBytes(Uint8List.fromList([..._ascii('ver'), 0])),
      'CLI: ver',
    );
    expect(
      await bridge
          .runCliCommandBytes(Uint8List.fromList([..._ascii('ver'), 0, 0])),
      'Error: illegal argument',
    );
    expect(await bridge.runCliCommandBytes(Uint8List.fromList([0x01])),
        'Error: illegal argument');
    expect(await bridge.runCliCommandBytes(Uint8List.fromList([0x7F])),
        'Error: illegal argument');
    expect(await bridge.runCliCommandBytes(Uint8List.fromList([0xFF])),
        'Error: illegal argument');
    expect(await bridge.runCliCommandBytes(Uint8List(0)), 'CLI: ');
  });

  test('CompanionOperationError formats its flags', () {
    const plain = CompanionOperationError(errCodeIllegalArg);
    expect(plain.toString(), contains('code=6'));
    expect(plain.toString(), isNot(contains('disabled')));
    expect(plain.toString(), isNot(contains('uncertain')));

    const full = CompanionOperationError(
      errCodeBadState,
      message: 'timed out',
      disabled: true,
      uncertain: true,
    );
    expect(full.toString(), contains('disabled'));
    expect(full.toString(), contains('uncertain'));
    expect(full.toString(), contains('timed out'));
  });

  test('operation error text maps every wire code', () {
    expect(
      companionOperationErrorText(
        const CompanionOperationError(errCodeIllegalArg),
      ),
      'Error: illegal argument',
    );
    expect(
      companionOperationErrorText(
        const CompanionOperationError(errCodeFileIoError),
      ),
      'Error: storage failure',
    );
    expect(
      companionOperationErrorText(
        const CompanionOperationError(errCodeTableFull),
      ),
      'Error: storage failure',
    );
    expect(
      companionOperationErrorText(
        const CompanionOperationError(errCodeBadState),
      ),
      'Error: device unavailable',
    );
    expect(
      companionOperationErrorText(
        const CompanionOperationError(errCodeUnsupportedCmd),
      ),
      'Error: unsupported',
    );
    expect(
      companionOperationErrorText(
        const CompanionOperationError(errCodeIllegalArg, disabled: true),
      ),
      'Error: disabled',
    );
  });
}

Uint8List _ascii(String value) => Uint8List.fromList(value.codeUnits);

class _CliBridge extends CompanionBridge {
  @override
  Future<String?> runCliCommand(String command) async => 'CLI: $command';
}

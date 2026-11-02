import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  late CompanionBridge bridge;

  setUp(() => bridge = CompanionBridge());

  test('push sink can be attached and cleared', () {
    expect(bridge.pushSink, isNull);
    final sink = _NoopSink();
    bridge.setPushSink(sink);
    expect(bridge.pushSink, same(sink));
    bridge.setPushSink(null);
    expect(bridge.pushSink, isNull);
  });

  test('local information defaults are conservative', () async {
    final prefs = bridge.getSelfInfo();
    expect(prefs.nodeName, 'MeshChameleon');
    expect(prefs.frequencyHz, 915000000);

    expect(bridge.getDeviceInfo().manufacturer, 'MeshChameleon');
    expect(bridge.maxChannels, 8);
    expect(bridge.getPathHashMode(), bridge.getDeviceInfo().pathHashMode);
    expect(bridge.getTime(), isNonZero);
    expect(bridge.setTime(1234), isTrue);

    final battery = await bridge.getBatteryAndStorage();
    expect(battery.millivolts, 0);
    expect(battery.storageUsedKb, 0);
    expect(battery.storageTotalKb, 0);

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
  });

  test('unsupported identity operations throw UnsupportedError', () async {
    expect(() => bridge.getPublicKey(), throwsUnsupportedError);
    await expectLater(bridge.exportPrivateKey(), throwsUnsupportedError);
    await expectLater(
      bridge.importPrivateKey(Uint8List(64)),
      throwsUnsupportedError,
    );
    expect(() => bridge.sign(Uint8List(0)), throwsUnsupportedError);
  });

  test('state-changing operations are no-ops that do not throw', () async {
    await bridge.addUpdateContact(Contact(publicKey: Uint8List(32)));
    await bridge.removeContact(Uint8List(32));
    await bridge.resetPath(Uint8List(32));
    await bridge.setChannel(0, 'name', Uint8List(16));
    await bridge.setAdvertName('name');
    await bridge.setAdvertLatLon(1, 2);
    await bridge.setRadioParams(1, 2, 3, 4);
    await bridge.setTxPower(10);
    await bridge.setPathHashMode(1);
    await bridge.setTuningParams(1, 2);
    await bridge.setAutoAddConfig(1, 2);
    await bridge.setOtherParams(manualAddContacts: 1);
    await bridge.setDefaultFloodScope('scope', Uint8List(16));
    await bridge.reboot();
    bridge.setFloodScopeKey(Uint8List(16));
    bridge.setFloodUnscoped();
  });

  test('broadcast/send operations default to failure or empty results',
      () async {
    expect(await bridge.sendChannelMessage(0, 'hi'), isFalse);
    expect(await bridge.sendChannelData(0, 1, Uint8List(1)), isFalse);
    expect(await bridge.advertise(), isFalse);
    expect(await bridge.runCliCommand('ver'), isNull);
    expect(await bridge.getAllowedRepeatFreq(), isEmpty);
    expect(await bridge.exportContact(null), isNull);
    expect(await bridge.importContact(Uint8List(1)), isFalse);
    expect(await bridge.shareContact(Uint8List(32)), isFalse);
    expect(
      await bridge.sendRawData(Uint8List(4), Uint8List(0), 0),
      isFalse,
    );
    expect(await bridge.sendRawPacket(Packet(), 0), isFalse);
    expect(await bridge.syncNextMessage(), isNull);
    expect(await bridge.getStats(statsTypeCore), isEmpty);
    expect(await bridge.sendControlData(Uint8List(1)), isFalse);
    expect(await bridge.getTuningParams(), isA<TuningParams>());

    for (final result in [
      await bridge.sendTextMessage(Uint8List(32), 'hi'),
      await bridge.sendBinaryReq(Uint8List(32), Uint8List(1)),
      await bridge.sendAnonReq(Uint8List(32), Uint8List(1)),
      await bridge.sendTelemetryRequest(Uint8List(32)),
      await bridge.sendPathDiscoveryReq(Uint8List(32)),
      await bridge.sendLogin(Uint8List(32), 'pw'),
      await bridge.sendStatusReq(Uint8List(32)),
    ]) {
      expect(result.success, isFalse);
    }
    expect(
      await bridge.sendTracePathRaw(1, 2, 0, Uint8List(0)),
      isFalse,
    );
    expect(bridge.logout(Uint8List(32)), isFalse);
    expect(bridge.hasConnection(Uint8List(32)), isFalse);
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
}

Uint8List _ascii(String value) => Uint8List.fromList(value.codeUnits);

class _NoopSink implements CompanionPushSink {
  @override
  void pushAdvert(Uint8List pubkey) {}
  @override
  void pushBinaryResponse(int tag, Uint8List data) {}
  @override
  void pushContactDeleted(Uint8List pubkey) {}
  @override
  void pushContactsFull() {}
  @override
  void pushControlData(double snr, int rssi, int pathLen, Uint8List data) {}
  @override
  void pushLoginFail(Uint8List pubkeyPrefix6) {}
  @override
  void pushLoginSuccess(
    Uint8List pubkeyPrefix6, {
    bool legacy = false,
    int permissions = 0,
    int serverTag = 0,
    int acl = 0,
    int firmwareVer = 0,
  }) {}
  @override
  void pushMsgWaiting() {}
  @override
  void pushNewAdvert(Uint8List contactFrame) {}
  @override
  void pushPathDiscoveryResponse(
    Uint8List pubkeyPrefix6,
    int outPathLen,
    Uint8List outPath,
    int inPathLen,
    Uint8List inPath,
  ) {}
  @override
  void pushPathUpdated(Uint8List pubkey) {}
  @override
  void pushRawData(double snr, int rssi, Uint8List payload) {}
  @override
  void pushRawRxData(double snr, int rssi, Uint8List raw) {}
  @override
  void pushSendConfirmed(int ackCrc, {int tripTimeMs = 0}) {}
  @override
  void pushStatusResponse(Uint8List pubkeyPrefix6, Uint8List data) {}
  @override
  void pushTelemetryResponse(Uint8List pubkeyPrefix6, Uint8List data) {}
  @override
  void pushTraceData(
    int pathLen,
    int flags,
    int tag,
    int authCode,
    Uint8List pathHashes,
    Uint8List pathSnrs,
    int finalSnrByte,
  ) {}
}

class _CliBridge extends CompanionBridge {
  @override
  Future<String?> runCliCommand(String command) async => 'CLI: $command';
}

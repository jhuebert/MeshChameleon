import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  late NodePrefs prefs;
  late _FailingLink link;
  late PhysicalRadio radio;

  setUp(() {
    prefs = NodePrefs();
    link = _FailingLink();
    radio = PhysicalRadio(
      link: link,
      prefs: prefs,
      capabilities: const PhysicalCapabilities(
        firmwareVerCode: 14,
        maxTxPower: 22,
      ),
      onPersist: () {},
      onConfigChanged: () {},
    );
  });

  RadioParams params({int freq = 915000000}) => RadioParams(
        frequencyHz: freq,
        bandwidthHz: 250000,
        spreadingFactor: 10,
        codingRate: 5,
      );

  test('setRadioParams validates every radio field', () async {
    await expectLater(
      radio.setRadioParams(149999999, 250000, 10, 5),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeIllegalArg)),
    );
    await expectLater(
      radio.setRadioParams(2500000001, 250000, 10, 5),
      throwsA(isA<CompanionOperationError>()),
    );
    await expectLater(
      radio.setRadioParams(915000000, 6999, 10, 5),
      throwsA(isA<CompanionOperationError>()),
    );
    await expectLater(
      radio.setRadioParams(915000000, 500001, 10, 5),
      throwsA(isA<CompanionOperationError>()),
    );
    await expectLater(
      radio.setRadioParams(915000000, 250000, 4, 5),
      throwsA(isA<CompanionOperationError>()),
    );
    await expectLater(
      radio.setRadioParams(915000000, 250000, 13, 5),
      throwsA(isA<CompanionOperationError>()),
    );
    await expectLater(
      radio.setRadioParams(915000000, 250000, 10, 4),
      throwsA(isA<CompanionOperationError>()),
    );
    await expectLater(
      radio.setRadioParams(915000000, 250000, 10, 9),
      throwsA(isA<CompanionOperationError>()),
    );
  });

  test('client repeat is rejected below firmware v9', () async {
    final oldRadio = PhysicalRadio(
      link: link,
      prefs: prefs,
      capabilities: const PhysicalCapabilities(firmwareVerCode: 8),
      onPersist: () {},
      onConfigChanged: () {},
    );
    await expectLater(
      oldRadio.setRadioParams(915000000, 250000, 10, 5, clientRepeat: true),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeUnsupportedCmd)),
    );
  });

  test('a definite radio write failure maps without marking the cache',
      () async {
    link.radioParamsError =
        const DeviceCommandError.device(errCodeIllegalArg, message: 'rejected');
    await expectLater(
      radio.setRadioParams(915000000, 250000, 10, 5),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeIllegalArg)
          .having((e) => e.uncertain, 'uncertain', isFalse)),
    );
    expect(radio.cacheUncertain, isFalse);
    expect(radio.diagnostic, 'rejected');
  });

  test('an uncertain radio write leaves the cache unverified', () async {
    link.radioParamsError = const DeviceCommandError.timeout();
    await expectLater(
      radio.setRadioParams(915000000, 250000, 10, 5),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.uncertain, 'uncertain', isTrue)),
    );
    expect(radio.cacheUncertain, isTrue);
    expect(radio.cacheVerified, isFalse);
  });

  test('setTxPower validates bounds and maps device failures', () async {
    await expectLater(
      radio.setTxPower(-10),
      throwsA(isA<CompanionOperationError>()),
    );
    await expectLater(
      radio.setTxPower(23),
      throwsA(isA<CompanionOperationError>()),
    );

    link.txPowerError =
        const DeviceCommandError.device(errCodeBadState, message: 'no tx');
    await expectLater(
      radio.setTxPower(10),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeBadState)),
    );
    expect(radio.diagnostic, 'no tx');

    link.txPowerError = const DeviceCommandError.timeout();
    await expectLater(
      radio.setTxPower(10),
      throwsA(isA<CompanionOperationError>()),
    );
    expect(radio.cacheUncertain, isTrue);
    expect(radio.cacheVerified, isFalse);
  });

  test('getTuningParams reconciles an uncertain cache first', () async {
    link.txPowerError = const DeviceCommandError.timeout();
    await expectLater(radio.setTxPower(10), throwsA(anything));
    expect(radio.cacheUncertain, isTrue);

    final tuning = await radio.getTuningParams();
    expect(tuning.rxDelayBaseMs, 0);
    expect(radio.cacheUncertain, isFalse);
    expect(link.calls, contains('selfInfo'));
  });

  test('getTuningParams keeps a cached value on a read failure', () async {
    await radio.getTuningParams();
    expect(radio.tuningCacheVerified, isTrue);

    link.tuningParamsError =
        const DeviceCommandError.timeout(message: 'unavailable');
    final cached = await radio.getTuningParams();
    expect(cached.rxDelayBaseMs, 0);
    expect(radio.tuningCacheVerified, isFalse);
    expect(radio.diagnostic, 'unavailable');
  });

  test('getTuningParams fails without a cache', () async {
    link.tuningParamsError = const DeviceCommandError.timeout();
    await expectLater(
      radio.getTuningParams(),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeBadState)),
    );
  });

  test('setTuningParams maps write and readback failures', () async {
    link.tuningError =
        const DeviceCommandError.device(errCodeIllegalArg, message: 'bad');
    await expectLater(
      radio.setTuningParams(1, 2),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeIllegalArg)),
    );

    link.tuningError = const DeviceCommandError.timeout();
    await expectLater(radio.setTuningParams(1, 2), throwsA(anything));
    expect(radio.cacheUncertain, isTrue);

    link.tuningError = null;
    link.tuningParamsError = const DeviceCommandError.timeout(message: 'read');
    await radio.setTuningParams(3, 4);
    expect(prefs.rxDelayBaseMs, 3);
    expect(radio.tuningCacheVerified, isFalse);
    expect(radio.diagnostic, 'read');
  });

  test('physical CLI failures record diagnostics and uncertain caches',
      () async {
    final spec = CliPhysicalValidator.validate('get radio', maxTxPower: 22);
    radio.recordPhysicalCliFailure(
      const DeviceCommandError.timeout(message: 'cli timeout'),
      spec,
    );
    expect(radio.diagnostic, 'cli timeout');
    expect(radio.cacheUncertain, isTrue);

    radio.recordCliOperationFailure(
      const CompanionOperationError(errCodeFileIoError, message: 'io'),
    );
    expect(radio.diagnostic, 'io');
  });

  test('a physical CLI tuning refresh failure is diagnostic only', () async {
    link.tuningParamsError =
        const DeviceCommandError.timeout(message: 'refresh failed');
    final spec = CliPhysicalValidator.validate('get af', maxTxPower: 22);
    final reply = await radio.runPhysicalCli(spec);
    expect(reply, isEmpty);
    expect(radio.tuningCacheVerified, isFalse);
    expect(radio.diagnostic, 'refresh failed');
  });

  test('getAllowedRepeatFreq maps device failures', () async {
    link.allowedFreqError = const DeviceCommandError.timeout();
    await expectLater(
      radio.getAllowedRepeatFreq(),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeBadState)),
    );
  });

  test('refreshNoiseFloor keeps the last value when unavailable', () async {
    expect(await radio.refreshNoiseFloor(), 0);
    await link.connect();
    expect(await radio.refreshNoiseFloor(), -110);

    link.radioStatsError = const DeviceCommandError.timeout();
    expect(await radio.refreshNoiseFloor(), -110);
  });

  test('syncPhysicalState adopts a snapshot without device I/O', () {
    radio.syncPhysicalState(
      params: params(freq: 869000000),
      tuning: const TuningParams(rxDelayBaseMs: 4, airtimeFactorMs: 5),
      capabilities: const PhysicalCapabilities(
        firmwareVerCode: 12,
        maxTxPower: 28,
      ),
    );
    expect(prefs.frequencyHz, 869000000);
    expect(prefs.rxDelayBaseMs, 4);
    expect(radio.capabilities.firmwareVerCode, 12);
    expect(prefs.maxTxPower, 28,
        reason: 'SELF_INFO must report the physical TX limit');
    expect(radio.diagnostic, isNull);
    expect(link.calls, isNot(contains('selfInfo')));
  });
}

class _FailingLink extends FakeDeviceLink {
  DeviceCommandError? txPowerError;
  DeviceCommandError? allowedFreqError;
  DeviceCommandError? radioStatsError;

  @override
  Future<void> setTxPower(int dbm) async {
    if (txPowerError != null) throw txPowerError!;
    return super.setTxPower(dbm);
  }

  @override
  Future<Uint8List> getAllowedRepeatFreq() async {
    if (allowedFreqError != null) throw allowedFreqError!;
    return super.getAllowedRepeatFreq();
  }

  @override
  Future<RadioStats> radioStats() async {
    if (radioStatsError != null) throw radioStatsError!;
    return super.radioStats();
  }
}

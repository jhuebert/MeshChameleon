import 'dart:async';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  late FakeDeviceLink base;
  late SharedRadioHub hub;

  setUp(() async {
    base = FakeDeviceLink();
    hub = SharedRadioHub(base);
    await base.connect();
  });

  tearDown(() async {
    hub.dispose();
    await base.disconnect();
  });

  test('fans one received frame out to every subscribed view', () async {
    final a = hub.viewFor('a');
    final b = hub.viewFor('b');
    final aFrames = <Uint8List>[];
    final bFrames = <Uint8List>[];
    a.setRawRxListener((snr, rssi, raw) => aFrames.add(raw));
    b.setRawRxListener((snr, rssi, raw) => bFrames.add(raw));
    hub.attach();

    base.deliver(2.5, -80, Uint8List.fromList([1, 2, 3]));

    expect(aFrames, hasLength(1));
    expect(bFrames, hasLength(1));
    expect(aFrames.single, [1, 2, 3]);
    expect(bFrames.single, [1, 2, 3]);
  });

  test('removing one listener does not affect the other', () async {
    final a = hub.viewFor('a');
    final b = hub.viewFor('b');
    var aCount = 0;
    var bCount = 0;
    a.setRawRxListener((_, __, ___) => aCount++);
    b.setRawRxListener((_, __, ___) => bCount++);
    hub.attach();

    a.setRawRxListener(null);
    base.deliver(0, 0, Uint8List.fromList([9]));

    expect(aCount, 0);
    expect(bCount, 1);
  });

  test('one throwing listener does not skip the others', () async {
    final a = hub.viewFor('a');
    final b = hub.viewFor('b');
    var bCount = 0;
    a.setRawRxListener((_, __, ___) => throw StateError('boom'));
    b.setRawRxListener((_, __, ___) => bCount++);
    hub.attach();

    base.deliver(0, 0, Uint8List.fromList([9]));

    expect(bCount, 1);
  });

  test('detach stops delivery and attach resumes it', () async {
    final a = hub.viewFor('a');
    var count = 0;
    a.setRawRxListener((_, __, ___) => count++);
    hub.attach();
    await hub.detach();

    base.deliver(0, 0, Uint8List.fromList([1]));
    expect(count, 0);

    hub.attach();
    base.deliver(0, 0, Uint8List.fromList([2]));
    expect(count, 1);
  });

  test('battery reads are coalesced and cached', () async {
    final a = hub.viewFor('a');
    final b = hub.viewFor('b');
    base.batteryAck = Completer<void>();

    final first = a.battery();
    final second = b.battery();
    await Future<void>.delayed(Duration.zero);
    expect(base.batteryReads, 1);

    base.batteryAck!.complete();
    final readings = await Future.wait([first, second]);
    expect(readings.first!.millivolts, 4000);

    await a.battery();
    expect(base.batteryReads, 1, reason: 'fresh sample is reused');
  });

  test('an in-flight battery sample from a detached session is not reused',
      () async {
    final a = hub.viewFor('a');
    base.batteryAck = Completer<void>();
    final pending = a.battery();
    await Future<void>.delayed(Duration.zero);
    expect(base.batteryReads, 1);

    await hub.detach();
    hub.attach();
    base.batteryAck!.complete();
    await pending;
    base.batteryAck = null;

    await a.battery();
    expect(base.batteryReads, 2,
        reason: 'the old session sample must not seed the new cache');
  });

  test('battery failures are not cached as successes', () async {
    final a = hub.viewFor('a');
    base.batteryError = const DeviceCommandError.device(errCodeFileIoError);
    await expectLater(a.battery(), throwsA(isA<DeviceCommandError>()));

    base.batteryError = null;
    final reading = await a.battery();
    expect(reading!.millivolts, 4000);
    expect(base.batteryReads, 2);
  });

  test('raw transmissions are serialized on the shared link', () async {
    final a = hub.viewFor('a');
    final b = hub.viewFor('b');
    base.rawTxAck = Completer<void>();

    final first = a.sendRawPacket(Uint8List.fromList([1]));
    final second = b.sendRawPacket(Uint8List.fromList([2]));
    await Future<void>.delayed(Duration.zero);
    expect(base.transmitted, hasLength(1));

    base.rawTxAck!.complete();
    await Future.wait([first, second]);
    expect(base.transmitted, hasLength(2));
  });

  test('state and configuration delegate to the base link', () async {
    final a = hub.viewFor('a');
    expect(a.currentState, LinkState.connected);
    expect(await a.selfInfo(), isNotNull);
    await a.setTxPower(10);
    expect(base.calls, contains('setTxPower'));
  });

  test('nodes never own link lifecycle', () async {
    final a = hub.viewFor('a');
    expect(a.connect, throwsUnsupportedError);
    expect(a.disconnect, throwsUnsupportedError);
  });

  test('views delegate every device operation to the base link', () async {
    final a = hub.viewFor('a');

    expect(await a.deviceInfo(), isNotNull);
    expect(await a.radioParams(), isNotNull);
    expect(await a.radioStats(), isNotNull);
    await a.setRadioParams(
      const RadioParams(
        frequencyHz: 869000000,
        bandwidthHz: 125000,
        spreadingFactor: 11,
        codingRate: 5,
      ),
      clientRepeat: true,
    );
    await a.setTxPower(17);
    await a.reboot();
    await a.shutdown();
    await a.setTuningParams(
      const TuningParams(rxDelayBaseMs: 5, airtimeFactorMs: 6),
    );
    await a.setPathHashMode(2);
    await a.runCliCommand('ver');
    await a.getAllowedRepeatFreq();

    expect(a.state, isA<Stream<LinkState>>());
    expect(a.currentState, base.currentState);
    expect(base.lastClientRepeat, isTrue);
    expect(base.pathHashMode, 2);
    expect(base.rebootRequests, 1);
    expect(base.shutdownRequests, 1);
    expect(base.cliCommands, containsAll(['ver', 'poweroff']));
  });

  test('a failed shared transmission rejects only that caller', () async {
    final a = hub.viewFor('a');
    final b = hub.viewFor('b');
    base.rawTxError = const DeviceCommandError.timeout(message: 'no ack');

    await expectLater(
      a.sendRawPacket(Uint8List.fromList([1])),
      throwsA(isA<DeviceCommandError>()),
    );

    base.rawTxError = null;
    await b.sendRawPacket(Uint8List.fromList([2]));
    expect(base.transmitted.single, [2]);
  });

  test('re-registering the same listener does not duplicate frames', () async {
    final a = hub.viewFor('a');
    var count = 0;
    void listener(double snr, int rssi, Uint8List raw) => count++;
    a.setRawRxListener(listener);
    a.setRawRxListener(listener);
    hub.attach();

    base.deliver(0, 0, Uint8List.fromList([1]));
    expect(count, 1);
  });

  test('battery cache expires after the freshness window', () async {
    var now = DateTime.utc(2026, 1, 1);
    final localBase = FakeDeviceLink();
    final localHub = SharedRadioHub(
      localBase,
      batteryFreshFor: const Duration(seconds: 10),
      now: () => now,
    );
    addTearDown(() async {
      localHub.dispose();
      await localBase.disconnect();
    });
    await localBase.connect();
    final view = localHub.viewFor('a');

    await view.battery();
    expect(localBase.batteryReads, 1);

    now = now.add(const Duration(seconds: 9));
    await view.battery();
    expect(localBase.batteryReads, 1);

    now = now.add(const Duration(seconds: 2));
    await view.battery();
    expect(localBase.batteryReads, 2);
  });

  test('dispose is idempotent and blocks later attachment', () async {
    hub.dispose();
    hub.dispose();
    expect(hub.attach, throwsStateError);
  });

  test('dispatch is ignored before attach', () async {
    final a = hub.viewFor('a');
    var count = 0;
    a.setRawRxListener((_, __, ___) => count++);
    base.deliver(0, 0, Uint8List.fromList([1]));
    expect(count, 0);
  });
}

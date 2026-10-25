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
}

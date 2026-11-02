import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('tracks connection and connected-duration state', () {
    var now = DateTime.utc(2026, 1, 1);
    final metrics = LinkMetrics(now: () => now);

    metrics.connectionAttempt();
    metrics.connectionSucceeded();
    expect(metrics.connectAttempts, 1);
    expect(metrics.connectSuccesses, 1);
    expect(metrics.connected, isTrue);

    now = now.add(const Duration(seconds: 10));
    expect(metrics.currentSessionDuration, const Duration(seconds: 10));
    expect(metrics.totalConnected, const Duration(seconds: 10));

    metrics.disconnected();
    expect(metrics.connected, isFalse);
    expect(metrics.disconnects, 1);
    expect(metrics.totalConnected, const Duration(seconds: 10));

    metrics.disconnected();
    expect(metrics.disconnects, 1, reason: 'duplicate disconnect is ignored');

    metrics.disconnected(unexpected: true);
    expect(metrics.unexpectedDrops, 1);
  });

  test('counts raw TX/RX and device requests through the decorator', () async {
    final inner = FakeDeviceLink();
    final metrics = LinkMetrics();
    final link = MeteredRadioLink(inner, metrics: metrics);
    addTearDown(link.disconnect);

    await link.connect();
    await link.sendRawPacket(Uint8List.fromList([1, 2, 3, 4]));
    expect(metrics.rawTxPackets, 1);
    expect(metrics.rawTxBytes, 4);
    expect(metrics.deviceRequests, 1);

    var received = 0;
    link.setRawRxListener((snr, rssi, raw) {
      received++;
      expect(raw, [9, 8]);
    });
    inner.deliver(4.5, -60, Uint8List.fromList([9, 8]));
    expect(received, 1);
    expect(metrics.rawRxPackets, 1);
    expect(metrics.rawRxBytes, 2);
    expect(metrics.lastSnr, 4.5);
    expect(metrics.lastRssi, -60);

    link.setRawRxListener(null);
    inner.deliver(4.5, -60, Uint8List.fromList([9, 8]));
    expect(received, 1);
    expect(metrics.rawRxPackets, 1);

    await link.deviceInfo();
    expect(metrics.deviceRequests, 2);
  });

  test('records connect, raw TX, and request failures without swallowing them',
      () async {
    final inner = FakeDeviceLink(connectFailures: 1);
    final metrics = LinkMetrics();
    final link = MeteredRadioLink(inner, metrics: metrics);
    addTearDown(link.disconnect);

    await expectLater(link.connect(), throwsStateError);
    expect(metrics.connectAttempts, 1);
    expect(metrics.connectFailures, 1);
    expect(metrics.connected, isFalse);

    await link.connect();
    expect(metrics.connectSuccesses, 1);

    inner.rawTxError = const DeviceCommandError.timeout(message: 'no ack');
    await expectLater(
      link.sendRawPacket(Uint8List.fromList([1, 2, 3, 4])),
      throwsA(isA<DeviceCommandError>()),
    );
    expect(metrics.rawTxPackets, 0);
    expect(metrics.rawTxFailures, 1);
    expect(metrics.deviceRequestFailures, 1);
    expect(metrics.deviceTimeouts, 1);

    inner.deviceInfoError =
        const DeviceCommandError.timeout(message: 'no reply');
    await expectLater(link.deviceInfo(), throwsA(isA<DeviceCommandError>()));
    expect(metrics.deviceRequestFailures, 2);
    expect(metrics.deviceTimeouts, 2);
  });

  test('counts generic failures and records their last error', () async {
    final inner = FakeDeviceLink();
    final metrics = LinkMetrics();
    final link = MeteredRadioLink(inner, metrics: metrics);
    addTearDown(link.disconnect);
    await link.connect();

    inner.rawTxError = StateError('raw exploded');
    await expectLater(
      link.sendRawPacket(Uint8List.fromList([1])),
      throwsStateError,
    );
    expect(metrics.rawTxFailures, 1);
    expect(metrics.deviceRequestFailures, 1);
    expect(metrics.lastError, contains('raw exploded'));

    inner.deviceInfoError = null;
    final throwing = _ThrowingLink();
    final throwingMetrics = LinkMetrics();
    final throwingDecorator =
        MeteredRadioLink(throwing, metrics: throwingMetrics);
    await expectLater(throwingDecorator.deviceInfo(), throwsStateError);
    expect(throwingMetrics.deviceRequestFailures, 1);
    expect(throwingMetrics.lastError, contains('generic failure'));
  });

  test('decorator forwards every device operation', () async {
    final inner = FakeDeviceLink();
    final metrics = LinkMetrics();
    final link = MeteredRadioLink(inner, metrics: metrics);
    addTearDown(link.disconnect);
    await link.connect();

    await link.selfInfo();
    await link.radioParams();
    await link.radioStats();
    await link.setRadioParams(
        const RadioParams(
          frequencyHz: 869000000,
          bandwidthHz: 125000,
          spreadingFactor: 11,
          codingRate: 5,
        ),
        clientRepeat: true);
    await link.setTxPower(17);
    await link.reboot();
    await link.shutdown();
    await link.battery();
    await link.tuningParams();
    await link.setTuningParams(
      const TuningParams(rxDelayBaseMs: 10, airtimeFactorMs: 20),
    );
    await link.setPathHashMode(2);
    await link.runCliCommand('ver');
    await link.getAllowedRepeatFreq();

    expect(inner.lastClientRepeat, isTrue);
    expect(inner.pathHashMode, 2);
    expect(inner.rebootRequests, 1);
    expect(inner.shutdownRequests, 1);
    expect(inner.cliCommands, containsAll(['ver', 'poweroff']));
    expect(metrics.deviceRequests, 13);
    expect(metrics.deviceRequestFailures, 0);
    expect(link.state, isA<Stream<LinkState>>());
    expect(link.currentState, inner.currentState);
  });

  test('LinkMetrics handles repeated success and unexpected drops', () {
    var now = DateTime.utc(2026, 1, 1);
    final metrics = LinkMetrics(now: () => now);

    metrics.connectionSucceeded();
    now = now.add(const Duration(seconds: 3));
    metrics.connectionSucceeded();
    expect(metrics.connectSuccesses, 2);
    expect(metrics.connectedSince, DateTime.utc(2026, 1, 1),
        reason: 'a repeated success must not reset the session start');

    metrics.rawTxFailed(StateError('tx'));
    expect(metrics.rawTxFailures, 1);
    expect(metrics.lastError, contains('tx'));

    metrics.deviceRequestFailed(StateError('request'));
    expect(metrics.deviceRequestFailures, 1);
    expect(metrics.deviceTimeouts, 0);

    metrics.disconnected(unexpected: true);
    expect(metrics.disconnects, 1);
    expect(metrics.unexpectedDrops, 1);
    expect(metrics.currentSessionDuration, Duration.zero);
    expect(metrics.totalConnected, const Duration(seconds: 3));
  });
}

class _ThrowingLink extends FakeDeviceLink {
  @override
  Future<DeviceInfo> deviceInfo() async => throw StateError('generic failure');
}

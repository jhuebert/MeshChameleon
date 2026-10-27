import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/services/build_info.dart';
import 'package:meshchameleon/services/diagnostics_snapshot.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  test('formats the shared diagnostics report', () {
    final now = DateTime.utc(2026, 10, 26, 18, 57);
    final companion = CompanionMetrics(now: () => now)
      ..recordClientConnected('192.168.1.20')
      ..commandReceived(2)
      ..replySent(80)
      ..pushSent(7)
      ..appTargetVersionReceived(3);
    final link = LinkMetrics(now: () => now)
      ..connectionAttempt()
      ..connectionSucceeded()
      ..deviceRequest()
      ..rawTx(40)
      ..rawRx(6.0, -70, 30);

    final snapshot = DiagnosticsSnapshot(
      buildInfo: BuildInfo.fromPackageInfo(
        PackageInfo(
          appName: 'MeshChameleon',
          packageName: 'org.huebert.meshchameleon',
          version: '0.1.0',
          buildNumber: '1',
        ),
        commit: 'abcdef1234567890abcdef1234567890abcdef12',
        buildTime: '2026-10-26T18:57:00Z',
      ),
      generatedAt: now,
      appUptime: const Duration(minutes: 2, seconds: 5),
      proxyRunning: true,
      proxyPort: 5000,
      deviceConnected: true,
      deviceLabel: 'TCP 192.168.1.50:5000',
      deviceInfo: const DeviceInfo(
        firmwareVerCode: 14,
        manufacturer: 'MeshCore',
        version: 'v1.18.0',
      ),
      deviceSessionDuration: const Duration(seconds: 30),
      reconnectAttempts: 1,
      reconnectSuccesses: 1,
      foregroundServiceRunning: true,
      batteryOptimizationsIgnored: true,
      autoResume: true,
      identityDatabaseError: null,
      companion: companion,
      link: link,
      identities: const [
        IdentityDiagnostics(
          id: 'id-1',
          name: 'MeshChameleon',
          prefixHex: 'ABCD1234',
          active: true,
          live: true,
          contactCount: 3,
          channelCount: 2,
          queuedDirect: 1,
          queuedChannel: 0,
          packets: MeshPacketStats(
            sent: 4,
            received: 9,
            floodTx: 2,
            directTx: 2,
            floodRx: 7,
            directRx: 2,
            receiveErrors: 0,
            queueLength: 1,
            txAirSeconds: 1,
            rxAirSeconds: 2,
            lastRssi: -70,
            lastSnrScaled: 24,
            noiseFloor: -110,
          ),
        ),
      ],
      recentLogs: const ['2026-10-26T18:57:00Z  client connected'],
    );

    final report = snapshot.toReport();
    expect(report, contains('MeshChameleon diagnostics'));
    expect(report, contains('Version: 0.1.0'));
    expect(report, contains('Commit: abcdef123456'));
    expect(report, contains('Proxy: Listening on :5000'));
    expect(report, contains('Client address: 192.168.1.20'));
    expect(report, contains('Raw TX/RX packets: 1 / 1'));
    expect(report, contains('Physical radio totals are unique'));
    expect(report, contains('MeshChameleon [ABCD1234] (active)'));
    expect(report, contains('semantic TX/RX: 4 / 9'));
    expect(report, contains('client connected'));
    expect(report, isNot(contains('PRIVATE KEY')));
  });

  test('formats durations, bytes, and counts consistently', () {
    expect(formatDuration(const Duration(seconds: 5)), '5s');
    expect(formatDuration(const Duration(minutes: 2, seconds: 5)), '2m 5s');
    expect(
      formatDuration(const Duration(days: 1, hours: 2, minutes: 3, seconds: 4)),
      '1d 2h 3m',
    );
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(2 * 1024 * 1024), '2.0 MB');
    expect(formatCount(1234567), '1,234,567');
  });
}

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/screens/diagnostics_screen.dart';
import 'package:meshchameleon/services/build_info.dart';
import 'package:meshchameleon/services/diagnostics_snapshot.dart';
import 'package:provider/provider.dart';

import 'support/fake_app_state.dart';

void main() {
  testWidgets('diagnostics page renders every section without a device',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const MaterialApp(home: DiagnosticsScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('Information'), findsOneWidget);
    expect(find.text('Version'), findsOneWidget);
    expect(find.text('Uptime'), findsOneWidget);
    expect(find.text('MeshCore app'), findsOneWidget);
    expect(find.text('Device link'), findsOneWidget);
    expect(find.text('Mesh traffic'), findsOneWidget);
    expect(find.text('Backup & restore'), findsNothing);
    expect(find.text('Platform'), findsNothing);
    expect(find.text('Package'), findsNothing);
    expect(find.byTooltip('Copy diagnostics'), findsOneWidget);
    expect(find.text('Copy diagnostics'), findsNothing);
    expect(
        find.textContaining('This build was compiled without'), findsNothing);
    expect(find.textContaining('Physical counts are unique'), findsNothing);
    expect(find.textContaining('Includes local addresses'), findsNothing);

    // Dispose the periodic refresh timer before the test ends.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rich diagnostics render every conditional row', (tester) async {
    _setLargeView(tester);
    final now = DateTime.utc(2026, 1, 2, 3, 4, 5);
    final app = FakeAppState(
      diagnosticsBuilder: () => _richSnapshot(now),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: DiagnosticsScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('Client'), findsNothing);
    expect(find.text('Connected'), findsWidgets);
    expect(find.text('Address'), findsOneWidget);
    expect(find.text('192.168.1.20'), findsOneWidget);
    expect(find.text('Connected for'), findsOneWidget);
    expect(find.text('Last disconnect'), findsOneWidget);
    expect(find.text('client closed'), findsOneWidget);
    expect(find.text('Firmware'), findsOneWidget);
    expect(find.text('Last error'), findsOneWidget);
    expect(find.textContaining('link error'), findsOneWidget);
    expect(find.text('Signal'), findsNWidgets(2));
    expect(find.textContaining('-70 dBm'), findsWidgets);
    expect(find.text('Database'), findsOneWidget);
    expect(find.text('catalog damaged'), findsOneWidget);

    // The active identity is expanded, showing packet counters.
    expect(find.text('TX / RX'), findsNWidgets(2));
    expect(find.text('Queue'), findsOneWidget);
    expect(find.text('Airtime'), findsOneWidget);
    expect(find.text('Queued'), findsOneWidget);
    expect(find.textContaining('· active'), findsOneWidget);

    // Expand a disabled identity to show its unavailable reason.
    await tester.tap(find.text('Disabled one'));
    await tester.pumpAndSettle();
    expect(find.text('Disabled'), findsWidgets);
    expect(find.text('Reason'), findsOneWidget);
    expect(find.text('disabled identity'), findsOneWidget);

    // Expand a non-live enabled identity without a reason.
    await tester.tap(find.text('Idle one'));
    await tester.pumpAndSettle();
    expect(find.text('Not live'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('copy diagnostics writes the report and confirms',
      (tester) async {
    _setLargeView(tester);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    final app = FakeAppState(
      diagnosticsBuilder: () =>
          _richSnapshot(DateTime.utc(2026, 1, 2, 3, 4, 5)),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: DiagnosticsScreen()),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Copy diagnostics'));
    await tester.pump();

    expect(copied, contains('MeshChameleon diagnostics'));
    expect(find.text('Diagnostics copied'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the page refreshes on a timer and after scrolling',
      (tester) async {
    _setLargeView(tester);
    var refreshes = 0;
    late FakeAppState app;
    app = FakeAppState(
      diagnosticsBuilder: () {
        final seconds = refreshes + 1;
        refreshes++;
        return _richSnapshot(
          DateTime.utc(2026, 1, 2, 3, 4, 5),
          uptime: Duration(seconds: seconds),
        );
      },
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: DiagnosticsScreen()),
      ),
    );
    await tester.pump();
    expect(find.text('1s'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.text('2s'), findsOneWidget);
    expect(app.refreshes, greaterThanOrEqualTo(2));

    // Scroll pauses the timer; the end notification resumes it after 500 ms.
    await tester.drag(find.byType(ListView), const Offset(0, -100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    final before = app.refreshes;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(app.refreshes, greaterThan(before));

    await tester.pumpWidget(const SizedBox());
  });
}

void _setLargeView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 5000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

DiagnosticsSnapshot _richSnapshot(
  DateTime now, {
  Duration uptime = const Duration(seconds: 1),
}) {
  final companion = CompanionMetrics(now: () => now)
    ..recordClientConnected('192.168.1.20')
    ..clientDisconnected('client closed')
    ..recordClientConnected('192.168.1.20')
    ..appTargetVersionReceived(3);
  final link = LinkMetrics(now: () => now)
    ..connectionAttempt()
    ..connectionSucceeded()
    ..rawTx(40)
    ..rawRx(6.0, -70, 30)
    ..connectionFailed(StateError('link error'));
  return DiagnosticsSnapshot(
    buildInfo: const BuildInfo(version: '0.2.0', buildNumber: '1'),
    generatedAt: now,
    appUptime: uptime,
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
    reconnectAttempts: 2,
    reconnectSuccesses: 1,
    foregroundServiceRunning: true,
    batteryOptimizationsIgnored: false,
    autoResume: true,
    identityDatabaseError: 'catalog damaged',
    companion: companion,
    link: link,
    identities: const [
      IdentityDiagnostics(
        id: 'id-active',
        name: 'Active one',
        prefixHex: 'AABBCCDD',
        active: true,
        live: true,
        contactCount: 3,
        channelCount: 2,
        queuedDirect: 1,
        queuedChannel: 2,
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
      IdentityDiagnostics(
        id: 'id-disabled',
        name: 'Disabled one',
        prefixHex: '11223344',
        active: false,
        live: false,
        enabled: false,
        contactCount: 0,
        channelCount: 0,
        queuedDirect: 0,
        queuedChannel: 0,
        unavailableReason: 'disabled identity',
      ),
      IdentityDiagnostics(
        id: 'id-idle',
        name: 'Idle one',
        prefixHex: '55667788',
        active: false,
        live: false,
        contactCount: 1,
        channelCount: 1,
        queuedDirect: 0,
        queuedChannel: 0,
      ),
    ],
    recentLogs: const ['log'],
  );
}

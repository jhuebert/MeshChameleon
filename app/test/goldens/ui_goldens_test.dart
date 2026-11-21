// Deterministic render fixtures for the static UI review checkpoints.
//
// Goldens use the default test font environment and fixed 360 x 800 logical
// sizes with no animation or live updates. Capture provenance and updates are
// documented in DEVELOPMENT.md (## UI review captures).
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/app_route_observer.dart';
import 'package:meshchameleon/app_view_state.dart';
import 'package:meshchameleon/screens/about_screen.dart';
import 'package:meshchameleon/screens/home_screen.dart';
import 'package:meshchameleon/screens/settings_screen.dart';
import 'package:meshchameleon/theme/app_theme.dart';
import 'package:provider/provider.dart';

import '../support/fake_app_state.dart';

IdentitySummary _summary(String id, String name, int firstByte,
        {required bool active, required bool live, int waiting = 0}) =>
    IdentitySummary(
      id: id,
      name: name,
      publicKey: Uint8List(32)..[0] = firstByte,
      createdAt: 1,
      active: active,
      live: live,
      keyAvailable: true,
      channelCount: 2,
      contactCount: 4,
      queuedDirect: waiting,
      queuedChannel: 0,
    );

FakeAppState _fixture({bool connected = false, bool waiting = false}) {
  final active = _summary('a', 'Trail Crew', 0x5d,
      active: true, live: connected, waiting: 2);
  final other = _summary('b', 'Field Team', 0x4a,
      active: false, live: connected, waiting: 1);
  final app = FakeAppState()
    ..summaries = [active, other]
    ..activeSummary = active
    ..deviceConnected = connected
    ..deviceWaiting = waiting
    ..deviceLabel = connected || waiting ? 'MeshCore Example' : null
    ..phase = waiting ? DeviceLinkPhase.waiting : DeviceLinkPhase.idle
    ..lastSession = const SessionConfig(kind: DeviceTargetKind.ble)
    ..proxyStatus = connected ? ProxyStatus.running : ProxyStatus.stopped
    ..phoneBatteryPercent = 78
    ..radioHealth = connected
        ? RadioHealth(
            millivolts: 3910,
            storageUsedKb: 512,
            storageTotalKb: 4096,
            sampledAt: DateTime.utc(2026, 1, 1),
          )
        : null
    ..gpsScope = connected
        ? const GpsScope(
            identityId: 'a',
            identityName: 'Trail Crew',
            requested: false,
            configuredIntervalSeconds: 900,
          )
        : null;
  if (connected) {
    app.companionMetricsValue.recordClientConnected(null);
    app.linkMetricsValue.connectionSucceeded();
    app.linkMetricsValue.rawTxPackets = 128;
    app.linkMetricsValue.rawRxPackets = 342;
  }
  return app;
}

Future<FakeAppState> _pump(
  WidgetTester tester,
  FakeAppState app,
  Widget screen, {
  required ThemeData theme,
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ChangeNotifierProvider<AppViewState>.value(
    value: app,
    child: MaterialApp(
      theme: theme,
      themeMode: ThemeMode.dark,
      navigatorObservers: [appRouteObserver],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: screen,
    ),
  ));
  await tester.pumpAndSettle();
  await tester.pump();
  return app;
}

Future<void> _expectGolden(WidgetTester tester, String name) async {
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('$name.png'),
  );
}

void main() {
  testWidgets('home idle, dark', (tester) async {
    final app = await _pump(tester, _fixture(), const HomeScreen(),
        theme: MeshChameleonTheme.dark());
    await _expectGolden(tester, 'home_idle_dark');
    app.dispose();
  });

  testWidgets('home idle, light', (tester) async {
    final app = await _pump(tester, _fixture(), const HomeScreen(),
        theme: MeshChameleonTheme.light());
    await _expectGolden(tester, 'home_idle_light');
    app.dispose();
  });

  testWidgets('home connected, dark', (tester) async {
    final app = await _pump(
        tester, _fixture(connected: true), const HomeScreen(),
        theme: MeshChameleonTheme.dark());
    await _expectGolden(tester, 'home_connected_dark');
    app.dispose();
  });

  testWidgets('home waiting recovery, dark', (tester) async {
    final app = await _pump(tester, _fixture(waiting: true), const HomeScreen(),
        theme: MeshChameleonTheme.dark());
    await _expectGolden(tester, 'home_waiting_dark');
    app.dispose();
  });

  testWidgets('home connected at 2x text scale, dark', (tester) async {
    final app = await _pump(
        tester, _fixture(connected: true), const HomeScreen(),
        theme: MeshChameleonTheme.dark(), scale: 2);
    await _expectGolden(tester, 'home_connected_large_text_dark');
    app.dispose();
  });

  testWidgets('identity switcher, dark', (tester) async {
    final app = await _pump(
        tester, _fixture(connected: true), const HomeScreen(),
        theme: MeshChameleonTheme.dark());
    await tester.tap(find.text('Switch'));
    await tester.pumpAndSettle();
    await _expectGolden(tester, 'switch_identity_sheet_dark');
    app.dispose();
  });

  testWidgets('settings, dark', (tester) async {
    final app = await _pump(
        tester, _fixture(connected: true), const SettingsScreen(),
        theme: MeshChameleonTheme.dark());
    await _expectGolden(tester, 'settings_dark');
    app.dispose();
  });

  testWidgets('settings, light', (tester) async {
    final app = await _pump(
        tester, _fixture(connected: true), const SettingsScreen(),
        theme: MeshChameleonTheme.light());
    await _expectGolden(tester, 'settings_light');
    app.dispose();
  });

  testWidgets('about, dark', (tester) async {
    final app = await _pump(tester, _fixture(), const AboutScreen(),
        theme: MeshChameleonTheme.dark());
    await _expectGolden(tester, 'about_dark');
    app.dispose();
  });
}

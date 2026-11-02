import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/main.dart';
import 'package:meshchameleon/services/identity_runtime.dart';
import 'package:provider/provider.dart';

import 'support/fake_app_state.dart';

void main() {
  _extraHomeTests();

  testWidgets('home screen renders identity, device, and proxy state',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    expect(find.text('MeshChameleon'), findsOneWidget);
    expect(find.text('Device link'), findsOneWidget);
    expect(find.text('No identity'), findsOneWidget);
    expect(find.text('Create an identity'), findsOneWidget);
    expect(find.text('Proxy server'), findsOneWidget);
    expect(find.text('Proxy server port'), findsOneWidget);
    expect(
      find.text('Reconnect the last device and restart the proxy on open'),
      findsOneWidget,
    );
    expect(find.text('Backup & restore'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Proxy server port')).dy,
      lessThan(tester.getTopLeft(find.text('Proxy server')).dy),
    );
    expect(find.text('Recent log'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('Ed25519'), findsNothing);
    expect(find.byTooltip('About & diagnostics'), findsOneWidget);
    expect(
        find.textContaining('MeshChameleon $productVersion'), findsOneWidget);
  });

  testWidgets('build footer opens the diagnostics page', (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    await tester.tap(find.textContaining('MeshChameleon $productVersion'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Information'), findsOneWidget);
    expect(find.text('Version'), findsOneWidget);
    expect(find.text('Uptime'), findsOneWidget);

    // Dispose the periodic diagnostics refresh before the test ends.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'battery card opens Android battery settings instead of prompting',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final app = AppState()..batteryOptimizationsIgnored = false;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    expect(find.text('Battery optimization'), findsOneWidget);
    expect(find.textContaining('Set MeshChameleon to Unrestricted'),
        findsOneWidget);
    expect(find.text('Open settings'), findsOneWidget);

    // The action opens system settings; the app never shows an exemption
    // prompt of its own.
    await tester.tap(find.text('Open settings'));
    await tester.pump();
  });

  testWidgets('battery card hides the settings action when unrestricted',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final app = AppState()..batteryOptimizationsIgnored = true;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    expect(find.textContaining('Unrestricted'), findsOneWidget);
    expect(find.text('Open settings'), findsNothing);
  });
}

// Additional HomeScreen coverage for live/connected states.

IdentitySummary _homeSummary({bool live = true}) => IdentitySummary(
      id: 'a' * 32,
      name: 'Home Identity',
      publicKey: Uint8List(32)..[0] = 0xAB,
      createdAt: 1,
      active: true,
      live: live,
      keyAvailable: true,
      channelCount: 1,
      contactCount: 2,
      queuedDirect: 0,
      queuedChannel: 0,
    );

void _homeView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _extraHomeTests() {
  testWidgets('connected running state shows live status and stops the proxy',
      (tester) async {
    _homeView(tester);
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary
      ..deviceConnected = true
      ..deviceLabel = 'TCP 192.168.1.50:5000'
      ..proxyStatus = ProxyStatus.running
      ..port = 5000;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    expect(find.textContaining('Home Identity (#AB000000)'), findsOneWidget);
    expect(find.textContaining('· Live'), findsOneWidget);
    expect(find.text('TCP 192.168.1.50:5000'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(find.text('Listening on port 5000'), findsOneWidget);

    await tester.tap(find.text('Disconnect'));
    await tester.pump();
    expect(app.disconnectCalls, 1);
    expect(find.text('Disconnect'), findsNothing);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Proxy server'));
    await tester.pumpAndSettle();
    expect(app.proxyStatus, ProxyStatus.stopped);
    final stoppedSwitch = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Proxy server'),
    );
    expect(stoppedSwitch.value, isFalse);
  });

  testWidgets('busy state disables controls and shows progress',
      (tester) async {
    _homeView(tester);
    final app = FakeAppState()..busy = true;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    final proxySwitch = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Proxy server'),
    );
    expect(proxySwitch.onChanged, isNull);
    final resumeSwitch = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Resume on launch'),
    );
    expect(resumeSwitch.onChanged, isNull);
  });

  testWidgets('the proxy port validates input and updates the app state',
      (tester) async {
    _homeView(tester);
    final app = FakeAppState()..port = 5000;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    await tester.tap(find.byTooltip('Save port'));
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '5000');

    await tester.enterText(find.byType(TextField), '0');
    await tester.tap(find.byTooltip('Save port'));
    await tester.pump();
    expect(find.text('Enter a port between 1 and 65535'), findsOneWidget);
    expect(app.port, 5000);

    await tester.enterText(find.byType(TextField), '70000');
    await tester.tap(find.byTooltip('Save port'));
    await tester.pump();
    expect(app.port, 5000);

    await tester.enterText(find.byType(TextField), '1234');
    await tester.tap(find.byTooltip('Save port'));
    await tester.pump();
    expect(app.port, 1234);
  });

  testWidgets('the battery card refreshes when the app resumes',
      (tester) async {
    _homeView(tester);
    final app = FakeAppState()..batteryOptimizationsIgnored = false;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();
    final before = app.batteryRefreshes;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(find.text('Open settings'), findsOneWidget);
    expect(app.batteryRefreshes, greaterThan(before));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the battery card is hidden off Android', (tester) async {
    _homeView(tester);
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>(
          create: (_) => FakeAppState(),
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      expect(find.text('Battery optimization'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/app_view_state.dart';
import 'package:meshchameleon/screens/settings_screen.dart';
import 'package:meshchameleon/theme/app_theme.dart';
import 'package:provider/provider.dart';

import 'support/fake_app_state.dart';

void main() {
  testWidgets('visible Settings actions have labeled Android-sized targets',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(ChangeNotifierProvider<AppViewState>(
      create: (_) => FakeAppState(),
      child: MaterialApp(
        theme: MeshChameleonTheme.dark(),
        home: const SettingsScreen(),
      ),
    ));
    await tester.pump();
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    semantics.dispose();
  });

  testWidgets('settings uses brief copy without the endpoint security note',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = FakeAppState();
    await tester.pumpWidget(ChangeNotifierProvider<AppViewState>.value(
      value: app,
      child: MaterialApp(
        theme: MeshChameleonTheme.dark(),
        home: const SettingsScreen(),
      ),
    ));
    await tester.pump();

    expect(find.text('Resume on launch'), findsOneWidget);
    expect(find.textContaining('Resume on app launch, not reboot'),
        findsOneWidget);
    expect(find.textContaining('Connect a radio first'), findsOneWidget);
    expect(
        find.textContaining('The proxy listener is plaintext'), findsNothing);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Resume on launch'));
    await tester.pump();
    expect(app.autoResume, isTrue);
    await tester.scrollUntilVisible(find.text('Use phone GPS'), 200);
    expect(find.textContaining('Unavailable while this identity is offline'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saved session has a concise launch description', (tester) async {
    final app = FakeAppState()
      ..lastSession = const SessionConfig(kind: DeviceTargetKind.tcp);
    await tester.pumpWidget(ChangeNotifierProvider<AppViewState>.value(
      value: app,
      child: MaterialApp(
        theme: MeshChameleonTheme.light(),
        home: const SettingsScreen(),
      ),
    ));
    await tester.pump();

    expect(find.text('Reconnect radio and proxy on app launch, not reboot.'),
        findsOneWidget);
    expect(find.textContaining('Connect a radio first'), findsNothing);
  });

  testWidgets('port editor retains invalid or failed drafts and rechecks state',
      (tester) async {
    final app = FakeAppState();
    await tester.pumpWidget(ChangeNotifierProvider<AppViewState>.value(
      value: app,
      child: MaterialApp(
        theme: MeshChameleonTheme.dark(),
        home: const SettingsScreen(),
      ),
    ));
    await tester.pump();
    await tester.tap(find.text('Proxy server port'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '0');
    await tester.tap(find.text('Save port'));
    await tester.pump();
    expect(find.textContaining('between 1 and 65535'), findsOneWidget);
    expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text, '0');
    await tester.enterText(find.byType(TextField), '8123');
    app.portSaveResult = false;
    await tester.tap(find.text('Save port'));
    await tester.pump();
    expect(find.textContaining('Could not save the port'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '8123');
    app.proxyStatus = ProxyStatus.running;
    app.notifyListeners();
    await tester.tap(find.text('Save port'));
    await tester.pump();
    expect(find.textContaining('Stop the proxy'), findsWidgets);
    expect(app.port, 5000);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(app.port, 5000);
  });

  testWidgets('GPS editor reads active scope rather than shared demand',
      (tester) async {
    final app = FakeAppState()
      ..phoneGpsRequested = true
      ..phoneGpsIntervalSeconds = 60
      ..gpsScope = const GpsScope(
        identityId: 'a',
        identityName: 'Alpha',
        requested: false,
        configuredIntervalSeconds: 900,
      );
    await tester.pumpWidget(ChangeNotifierProvider<AppViewState>.value(
      value: app,
      child: MaterialApp(
          theme: MeshChameleonTheme.dark(), home: const SettingsScreen()),
    ));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Use phone GPS'), 200);
    expect(
        tester
            .widget<SwitchListTile>(
                find.widgetWithText(SwitchListTile, 'Use phone GPS'))
            .value,
        isFalse);
    expect(find.text('Every 900 s'), findsOneWidget);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '900');
    await tester.enterText(find.byType(TextField), '123');
    app.busy = true;
    app.notifyListeners();
    await tester.tap(find.text('Save GPS interval'));
    await tester.pump();
    expect(find.textContaining('active identity changed or is busy'),
        findsOneWidget);
    expect(app.gpsIntervalCalls, isEmpty);
    app.busy = false;
    app.gpsScope = const GpsScope(
      identityId: 'b',
      identityName: 'Beta',
      requested: true,
      configuredIntervalSeconds: 60,
    );
    app.notifyListeners();
    await tester.tap(find.text('Save GPS interval'));
    await tester.pump();
    expect(find.textContaining('active identity changed'), findsOneWidget);
    expect(app.gpsIntervalCalls, isEmpty);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '123');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    app.gpsSaveResult = false;
    await tester.tap(find.widgetWithText(SwitchListTile, 'Use phone GPS'));
    await tester.pump();
    expect(find.text('Could not change phone GPS. Try again.'), findsOneWidget);
    expect(app.gpsScope!.requested, isTrue);
    app.gpsSaveResult = true;
    await tester.tap(find.widgetWithText(SwitchListTile, 'Use phone GPS'));
    await tester.pump();
    expect(find.text('Could not change phone GPS. Try again.'), findsNothing);
    expect(app.gpsScope!.requested, isFalse);
  });

  testWidgets('closing a pending port save does not pop Settings',
      (tester) async {
    final gate = Completer<bool>();
    final app = FakeAppState()..portSaveGate = gate;
    await tester.pumpWidget(ChangeNotifierProvider<AppViewState>.value(
      value: app,
      child: MaterialApp(
        theme: MeshChameleonTheme.dark(),
        home: const SettingsScreen(),
      ),
    ));
    await tester.pump();
    await tester.tap(find.text('Proxy server port'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '8123');
    await tester.tap(find.text('Save port'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    // Finish while the dismissed dialog's reverse transition is in progress.
    gate.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });
}

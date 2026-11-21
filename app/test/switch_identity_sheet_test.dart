import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/app_view_state.dart';
import 'package:meshchameleon/screens/switch_identity_sheet.dart';
import 'package:provider/provider.dart';

import 'support/fake_app_state.dart';

IdentitySummary summary(String id,
        {bool active = false, bool enabled = true, bool live = false}) =>
    IdentitySummary(
      id: id,
      name: id,
      publicKey: Uint8List(32),
      createdAt: 1,
      active: active,
      live: live,
      enabled: enabled,
      keyAvailable: true,
      channelCount: 0,
      contactCount: 0,
      queuedDirect: 0,
      queuedChannel: 0,
    );

void main() {
  Future<void> open(WidgetTester tester, FakeAppState app,
      {void Function(SwitchIdentityOutcome?)? onResult}) async {
    await tester.pumpWidget(ChangeNotifierProvider<AppViewState>.value(
      value: app,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final result = await showSwitchIdentitySheet(context);
                onResult?.call(result);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('offline selection works; failures remain in the sheet',
      (tester) async {
    final app = FakeAppState()
      ..summaries = [summary('Alpha', active: true), summary('Beta')]
      ..activateResult = false;
    await open(tester, app);
    await tester.tap(find.text('Alpha'));
    expect(app.activateCalls, isEmpty);
    await tester.tap(find.text('Beta'));
    await tester.pump();
    expect(app.activateCalls, ['Beta']);
    expect(find.text('Could not activate Beta'), findsOneWidget);
    expect(find.text('Manage identities'), findsOneWidget);
  });

  testWidgets('dismissal during activation never pops the underlying route',
      (tester) async {
    final gate = Completer<bool>();
    final app = FakeAppState()
      ..summaries = [summary('Alpha', active: true), summary('Beta')]
      ..activateGate = gate;
    await open(tester, app);
    await tester.tap(find.text('Beta'));
    await tester.pump();
    await tester.tap(find.text('Beta'), warnIfMissed: false);
    expect(app.activateCalls, ['Beta']);
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 400));
    gate.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Switch identity'), findsNothing);
  });

  testWidgets('disabled reason is visible and manage returns an outcome',
      (tester) async {
    final app = FakeAppState()
      ..summaries = [
        summary('Alpha', active: true),
        summary('Beta', enabled: false),
      ];
    SwitchIdentityOutcome? result;
    await open(tester, app, onResult: (value) => result = value);
    expect(find.textContaining('enable it to use it'), findsOneWidget);
    await tester.tap(find.text('Beta'), warnIfMissed: false);
    expect(app.activateCalls, isEmpty);
    await tester.tap(find.text('Manage identities'));
    await tester.pumpAndSettle();
    expect(result, SwitchIdentityOutcome.manage);
  });

  testWidgets('many identities remain scrollable at large text size',
      (tester) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = FakeAppState()
      ..summaries = [
        for (var i = 0; i < 12; i++) summary('Identity $i', active: i == 0),
      ];
    await tester.pumpWidget(ChangeNotifierProvider<AppViewState>.value(
      value: app,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSwitchIdentitySheet(context),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Manage identities'), 300);
    expect(find.text('Manage identities').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

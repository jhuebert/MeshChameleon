import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/main.dart' as app_main;
import 'package:meshchameleon/screens/home_screen.dart';
import 'package:meshchameleon/services/build_info.dart';

import 'support/fake_app_state.dart';

void main() {
  testWidgets('app shell installs the real theme and Home', (tester) async {
    final app = FakeAppState();
    await tester.pumpWidget(app_main.ProxyApp(
      buildInfo: const BuildInfo(version: '0.2.0'),
      createState: () => app,
    ));
    await tester.pump();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(MaterialApp), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('entry point initializes the app shell', (tester) async {
    await tester.runAsync(app_main.main);
    // Replace the scheduled shell before its provider creates real storage.
    await tester.pumpWidget(const SizedBox());
  });
}

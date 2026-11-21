import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/app_view_state.dart';
import 'package:meshchameleon/screens/about_screen.dart';
import 'package:meshchameleon/theme/app_theme.dart';
import 'package:provider/provider.dart';

import 'support/fake_app_state.dart';

void main() {
  testWidgets('About keeps build and legal details without extra sections',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(ChangeNotifierProvider<AppViewState>(
      create: (_) => FakeAppState(),
      child: MaterialApp(
          theme: MeshChameleonTheme.dark(), home: const AboutScreen()),
    ));
    expect(find.text('This build'), findsOneWidget);
    expect(find.textContaining('Built without'), findsNothing);
    expect(find.text('Source'), findsNothing);
    await tester.scrollUntilVisible(find.text('Open-source licenses'), 200);
    expect(find.textContaining('Copyright (c) 2026'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

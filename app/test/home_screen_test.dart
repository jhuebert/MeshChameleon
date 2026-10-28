import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/main.dart';
import 'package:provider/provider.dart';

void main() {
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
      tester.getTopLeft(find.text('Proxy server port')).dy,
      lessThan(tester.getTopLeft(find.text('Proxy server')).dy),
    );
    expect(find.text('Recent log'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('Ed25519'), findsNothing);
    expect(find.byTooltip('About & diagnostics'), findsOneWidget);
    expect(find.textContaining('MeshChameleon 0.1.0'), findsOneWidget);
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

    await tester.tap(find.textContaining('MeshChameleon 0.1.0'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Information'), findsOneWidget);
    expect(find.text('Version'), findsOneWidget);
    expect(find.text('Uptime'), findsOneWidget);

    // Dispose the periodic diagnostics refresh before the test ends.
    await tester.pumpWidget(const SizedBox());
  });
}

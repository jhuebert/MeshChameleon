import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/screens/diagnostics_screen.dart';
import 'package:provider/provider.dart';

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

    expect(find.text('About & diagnostics'), findsOneWidget);
    expect(find.text('Version'), findsOneWidget);
    expect(find.text('Uptime'), findsOneWidget);
    expect(find.text('MeshCore app'), findsOneWidget);
    expect(find.text('Device link'), findsOneWidget);
    expect(find.text('Mesh traffic'), findsOneWidget);
    expect(find.byTooltip('Copy diagnostics'), findsOneWidget);
    expect(find.text('Copy diagnostics'), findsNothing);
    expect(
        find.textContaining('This build was compiled without'), findsNothing);
    expect(find.textContaining('Physical counts are unique'), findsNothing);
    expect(find.textContaining('Includes local addresses'), findsNothing);

    // Dispose the periodic refresh timer before the test ends.
    await tester.pumpWidget(const SizedBox());
  });
}

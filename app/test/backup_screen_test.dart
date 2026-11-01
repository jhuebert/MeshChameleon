import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/screens/backup_screen.dart';
import 'package:meshchameleon/screens/diagnostics_screen.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('information screen opens backup and restore', (tester) async {
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

    expect(find.text('Backup & restore'), findsOneWidget);
    await tester.tap(find.text('Backup & restore'));
    await tester.pumpAndSettle();

    expect(find.text('One encrypted file'), findsOneWidget);
    expect(find.text('Back up now'), findsOneWidget);
    expect(find.text('Restore from backup'), findsOneWidget);
    expect(find.textContaining('private identity keys'), findsOneWidget);

    // Dispose the diagnostics refresh timer.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('backup passphrase requires a usable length', (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const MaterialApp(home: BackupScreen()),
      ),
    );

    await tester.tap(find.text('Back up now'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a backup passphrase'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'short');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Use at least 8 characters'), findsOneWidget);
  });
}

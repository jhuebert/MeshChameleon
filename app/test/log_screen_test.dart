import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/screens/log_screen.dart';
import 'package:provider/provider.dart';

import 'support/async_wait.dart';

void main() {
  testWidgets('log page renders entries and copies them', (tester) async {
    final app = AppState()..log('hello from the log');
    addTearDown(app.dispose);
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(
      ChangeNotifierProvider<AppViewState>.value(
        value: app,
        child: const MaterialApp(home: LogScreen()),
      ),
    );

    expect(find.textContaining('hello from the log'), findsOneWidget);
    expect(find.byTooltip('Copy log'), findsOneWidget);

    await tester.runAsync(() => tester.tap(find.byTooltip('Copy log')));
    await pumpUntil(
        tester, () => find.text('Log copied').evaluate().isNotEmpty);

    expect(find.text('Log copied'), findsOneWidget);
    final copy = calls.where((call) => call.method == 'Clipboard.setData');
    expect(copy, hasLength(1));
    expect(
        (copy.single.arguments as Map)['text'], contains('hello from the log'));
  });
}

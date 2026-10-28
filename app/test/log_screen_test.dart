import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/screens/log_screen.dart';
import 'package:provider/provider.dart';

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
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: LogScreen()),
      ),
    );

    expect(find.textContaining('hello from the log'), findsOneWidget);
    expect(find.byTooltip('Copy log'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Copy log'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    expect(find.text('Log copied'), findsOneWidget);
    final copy = calls.where((call) => call.method == 'Clipboard.setData');
    expect(copy, hasLength(1));
    expect(
        (copy.single.arguments as Map)['text'], contains('hello from the log'));
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/widgets/app_surfaces.dart';

void main() {
  testWidgets('ActionTile shows subtitle, trailing, and handles taps',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ActionTile(
            icon: Icons.link,
            title: 'Open',
            subtitle: 'Details',
            trailing: const Icon(Icons.arrow_forward),
            onTap: () => taps++,
          ),
        ),
      ),
    );

    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_forward), findsOneWidget);

    await tester.tap(find.text('Open'));
    expect(taps, 1);
  });

  testWidgets('ActionTile hides optional content and disables taps',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ActionTile(
            icon: Icons.link,
            title: 'Unavailable',
            onTap: () => taps++,
            enabled: false,
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    expect(find.text('Details'), findsNothing);

    await tester.tap(find.text('Unavailable'));
    expect(taps, 0);
  });

  testWidgets('StatusCard and BusyStrip render their content', (tester) async {
    // Keep this non-const so BusyStrip's constructor line is instrumented.
    // ignore: prefer_const_declarations
    final busyPadding = EdgeInsets.zero;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const StatusCard(
                margin: EdgeInsets.all(4),
                child: Text('Status'),
              ),
              BusyStrip(padding: busyPadding),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Status'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('ErrorBanner hides and shows its recovery action',
      (tester) async {
    var actions = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const ErrorBanner(
                title: 'No action',
                message: 'Nothing to do',
              ),
              ErrorBanner(
                title: 'Retry',
                message: 'Try again',
                actionLabel: 'Retry',
                onAction: () => actions++,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('No action'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    expect(actions, 1);
  });

  testWidgets('showConfirmDialog returns true for destructive confirms',
      (tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showConfirmDialog(
                context,
                title: 'Delete',
                message: 'Delete this identity?',
                confirmLabel: 'Delete',
                destructive: true,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
  });

  testWidgets('showConfirmDialog returns false for cancels', (tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showConfirmDialog(
                context,
                title: 'Continue',
                message: 'Continue?',
                confirmLabel: 'Continue',
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(result, isFalse);
  });

  testWidgets('showConfirmDialog returns false when dismissed', (tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showConfirmDialog(
                context,
                title: 'Continue',
                message: 'Continue?',
                confirmLabel: 'Continue',
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    expect(result, isFalse);
  });

  testWidgets('showErrorDialog closes with OK', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showErrorDialog(
              context,
              title: 'Error',
              message: 'Something failed',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Something failed'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'OK'));
    await tester.pumpAndSettle();
    expect(find.text('Something failed'), findsNothing);
  });
}

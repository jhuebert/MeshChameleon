import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/main.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('home screen renders proxy status', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    expect(find.text('MeshChameleon'), findsOneWidget);
    expect(find.text('Device link'), findsOneWidget);
    expect(find.text('Identity'), findsOneWidget);
    expect(find.text('Proxy server'), findsOneWidget);
    expect(find.text('Proxy server port'), findsOneWidget);
    expect(find.text('Recent log'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
  });
}

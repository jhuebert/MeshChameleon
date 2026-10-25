import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/screens/connect_screen.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/network_connection_store.dart';
import 'package:meshchameleon/services/session_store.dart';
import 'package:provider/provider.dart';

Widget _screen(DeviceCapabilities capabilities) => ChangeNotifierProvider(
      create: (_) => AppState(capabilities: capabilities),
      child: MaterialApp(home: ConnectScreen(capabilities: capabilities)),
    );

void main() {
  testWidgets('hides the BLE section when the platform has no BLE',
      (tester) async {
    await tester.pumpWidget(_screen(const DeviceCapabilities(
      supportsBle: false,
      supportsSimulatedCompanion: true,
    )));

    expect(find.text('Bluetooth companion'), findsNothing);
    expect(find.text('Network companion'), findsOneWidget);
    expect(find.text('Scan for MeshCore devices'), findsNothing);
    expect(find.text('Connect over TCP'), findsOneWidget);
    expect(find.text('Connect simulated companion'), findsOneWidget);
  });

  testWidgets('shows the BLE section where BLE is supported', (tester) async {
    await tester.pumpWidget(_screen(const DeviceCapabilities(
      supportsBle: true,
      supportsSimulatedCompanion: true,
    )));

    expect(find.text('Bluetooth companion'), findsOneWidget);
    expect(find.text('Scan for MeshCore devices'), findsOneWidget);
  });

  testWidgets('hides the simulated companion outside development builds',
      (tester) async {
    await tester.pumpWidget(_screen(const DeviceCapabilities(
      supportsBle: true,
      supportsSimulatedCompanion: false,
    )));

    expect(find.text('Simulated companion (development)'), findsNothing);
    expect(find.text('Connect simulated companion'), findsNothing);
  });

  testWidgets('the simulated companion entry connects and returns',
      (tester) async {
    // Setup runs outside the widget test's fake-async zone, so the real
    // filesystem and crypto work below completes.
    late Directory dir;
    late AppState app;
    const capabilities = DeviceCapabilities(
      supportsBle: false,
      supportsSimulatedCompanion: true,
    );

    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('meshchameleon_ui_');
      FlutterSecureStorage.setMockInitialValues({});
      final repository = IdentityRepository(
        supportDirectory: dir,
        secureStore: IdentityStore(),
      );
      app = AppState(
        repository: repository,
        sessionStore: SessionStore(file: File('${dir.path}/session.json')),
        networkConnectionStore: NetworkConnectionStore(
          file: File('${dir.path}/network_connections.json'),
        ),
        capabilities: capabilities,
      );
      await app.loadIdentities();
    });
    addTearDown(() async {
      await app.disconnectDevice();
      await dir.delete(recursive: true);
    });

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      const ConnectScreen(capabilities: capabilities),
                ),
              ),
              child: const Text('open connect'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open connect'));
    await tester.pumpAndSettle();

    // The connect completes a session write on the real filesystem, so drive
    // it in the real async zone before pumping the pop animation.
    await tester.runAsync(() async {
      await tester.tap(find.text('Connect simulated companion'));
      while (app.busy) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(app.deviceConnected, isTrue);
    expect(app.deviceLabel, 'Simulated companion');
    expect(find.text('open connect'), findsOneWidget);
  });
}

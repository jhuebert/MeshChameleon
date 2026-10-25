import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/screens/connect_screen.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/network_connection_store.dart';
import 'package:meshchameleon/services/session_store.dart';
import 'package:provider/provider.dart';

const _bleCapabilities = DeviceCapabilities(
  supportsBle: true,
  supportsSimulatedCompanion: true,
);

const _networkCapabilities = DeviceCapabilities(
  supportsBle: false,
  supportsSimulatedCompanion: false,
);

const _simulatedCapabilities = DeviceCapabilities(
  supportsBle: false,
  supportsSimulatedCompanion: true,
);

void main() {
  late Directory dir;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('mesh_connect_ui_');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  Future<AppState> pumpScreen(
    WidgetTester tester,
    DeviceCapabilities capabilities, {
    SessionConfig? session,
    NetworkConnectionStore? networkStore,
    TcpDeviceLinkFactory? tcpLinkFactory,
    bool push = false,
  }) async {
    late AppState app;
    await tester.runAsync(() async {
      final sessionStore = SessionStore(file: File('${dir.path}/session.json'));
      if (session != null) await sessionStore.save(session);
      app = AppState(
        repository: IdentityRepository(
          supportDirectory: dir,
          secureStore: IdentityStore(),
        ),
        sessionStore: sessionStore,
        networkConnectionStore: networkStore ??
            NetworkConnectionStore(
              file: File('${dir.path}/network_connections.json'),
            ),
        tcpLinkFactory: tcpLinkFactory,
        capabilities: capabilities,
      );
      await app.loadIdentities();
    });
    addTearDown(() async {
      await app.disconnectDevice();
      await app.manager?.dispose();
    });

    final screen = ConnectScreen(capabilities: capabilities);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          home: push
              ? Builder(
                  builder: (context) => TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => screen),
                    ),
                    child: const Text('open connect'),
                  ),
                )
              : screen,
        ),
      ),
    );
    if (push) {
      await tester.tap(find.text('open connect'));
    }
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('BLE builds show transport tabs and start on Bluetooth',
      (tester) async {
    await pumpScreen(tester, _bleCapabilities);

    expect(find.byType(TabBar), findsOneWidget);
    expect(find.text('Bluetooth'), findsOneWidget);
    expect(find.text('Network'), findsOneWidget);
    expect(find.text('Simulated'), findsOneWidget);
    expect(find.text('Bluetooth companion'), findsOneWidget);
    expect(find.text('Scan for MeshCore devices'), findsOneWidget);
    expect(find.text('Network companion'), findsNothing);
    expect(find.text('Connect over TCP'), findsNothing);
  });

  testWidgets('switching to Network hides the Bluetooth controls',
      (tester) async {
    await pumpScreen(tester, _bleCapabilities);

    await tester.tap(find.text('Network'));
    await tester.pumpAndSettle();

    expect(find.text('Network companion'), findsOneWidget);
    expect(find.text('Connect over TCP'), findsOneWidget);
    expect(find.text('Bluetooth companion'), findsNothing);
    expect(find.text('Scan for MeshCore devices'), findsNothing);
  });

  testWidgets('a non-BLE build has no Bluetooth tab and defaults to Network',
      (tester) async {
    await pumpScreen(tester, _networkCapabilities);

    expect(find.byType(TabBar), findsNothing);
    expect(find.text('Network companion'), findsOneWidget);
    expect(find.text('Connect over TCP'), findsOneWidget);
    expect(find.text('Bluetooth companion'), findsNothing);
    expect(find.text('Scan for MeshCore devices'), findsNothing);
    expect(find.text('Simulated'), findsNothing);
  });

  testWidgets('the simulated tab is only present in development builds',
      (tester) async {
    await pumpScreen(tester, _simulatedCapabilities);

    expect(find.text('Simulated'), findsOneWidget);
    await tester.tap(find.text('Simulated'));
    await tester.pumpAndSettle();
    expect(find.text('Simulated companion'), findsOneWidget);
    expect(find.text('Connect simulated companion'), findsOneWidget);
  });

  testWidgets('a release-shaped non-BLE build never shows simulated controls',
      (tester) async {
    await pumpScreen(tester, _networkCapabilities);

    expect(find.text('Simulated companion'), findsNothing);
    expect(find.text('Connect simulated companion'), findsNothing);
  });

  testWidgets('the last TCP session selects the Network tab', (tester) async {
    await pumpScreen(
      tester,
      _bleCapabilities,
      session: const SessionConfig(
        kind: DeviceTargetKind.tcp,
        host: '192.168.1.55',
        proxyPort: 0,
      ),
    );

    expect(find.text('Network companion'), findsOneWidget);
    expect(find.text('Host'), findsOneWidget);
    expect(find.text('Bluetooth companion'), findsNothing);
  });

  testWidgets('the last BLE session selects the Bluetooth tab', (tester) async {
    await pumpScreen(
      tester,
      _bleCapabilities,
      session: const SessionConfig(
        kind: DeviceTargetKind.ble,
        bleRemoteId: 'AA:BB:CC:DD:EE:FF',
        bleName: 'MeshCore-Test',
        proxyPort: 0,
      ),
    );

    expect(find.text('Bluetooth companion'), findsOneWidget);
    expect(find.text('Network companion'), findsNothing);
  });

  testWidgets('the simulated companion entry connects and returns',
      (tester) async {
    final app = await pumpScreen(tester, _simulatedCapabilities, push: true);

    await tester.tap(find.text('Simulated'));
    await tester.pumpAndSettle();
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

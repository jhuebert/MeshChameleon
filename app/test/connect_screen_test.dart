import 'dart:io';

import 'package:device_link/device_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
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

NetworkConnectionStore _historyStore(Directory dir) => NetworkConnectionStore(
      file: File('${dir.path}/network_connections.json'),
    );

SavedNetworkConnection _recentConnection(
  String host, {
  int port = defaultCompanionPort,
  Duration age = const Duration(minutes: 2),
}) =>
    SavedNetworkConnection(
      host: host,
      port: port,
      lastConnectedAt:
          DateTime.now().toUtc().subtract(age).millisecondsSinceEpoch,
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
        networkConnectionStore: networkStore ?? _historyStore(dir),
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

  testWidgets('saved cards render newest-first and prefill the form',
      (tester) async {
    final store = _historyStore(dir);
    await tester.runAsync(() async {
      await store.save([
        _recentConnection(
          'older.example',
          port: 5000,
          age: const Duration(hours: 3),
        ),
        _recentConnection(
          'newer.example',
          port: 6000,
          age: const Duration(minutes: 5),
        ),
      ]);
    });

    await pumpScreen(tester, _networkCapabilities, networkStore: store);

    expect(find.text('Saved connections'), findsOneWidget);
    expect(find.text('newer.example:6000'), findsOneWidget);
    expect(find.text('older.example:5000'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('newer.example:6000')).dy,
      lessThan(tester.getTopLeft(find.text('older.example:5000')).dy),
    );
    expect(find.text('Last connected 5 minutes ago'), findsOneWidget);

    final fields =
        tester.widgetList<TextFormField>(find.byType(TextFormField)).toList();
    expect(fields[0].controller!.text, 'newer.example');
    expect(fields[1].controller!.text, '6000');
  });

  testWidgets('an empty history keeps the form usable and explains the list',
      (tester) async {
    await pumpScreen(tester, _networkCapabilities);

    expect(
      find.text(
        'Successful network connections appear here for quick reconnects.',
      ),
      findsOneWidget,
    );
    final fields =
        tester.widgetList<TextFormField>(find.byType(TextFormField)).toList();
    expect(fields[0].controller!.text, '192.168.1.100');
    expect(fields[1].controller!.text, defaultCompanionPort.toString());
  });

  testWidgets('an empty history falls back to the last TCP session',
      (tester) async {
    await pumpScreen(
      tester,
      _networkCapabilities,
      session: const SessionConfig(
        kind: DeviceTargetKind.tcp,
        host: 'session.example',
        devicePort: 5001,
        proxyPort: 0,
      ),
    );

    final fields =
        tester.widgetList<TextFormField>(find.byType(TextFormField)).toList();
    expect(fields[0].controller!.text, 'session.example');
    expect(fields[1].controller!.text, '5001');
  });

  testWidgets('deleting a saved connection removes it and Undo restores it',
      (tester) async {
    final original = _recentConnection('delete.example');
    final store = _historyStore(dir);
    await tester.runAsync(() => store.save([original]));
    final app = await pumpScreen(
      tester,
      _networkCapabilities,
      networkStore: store,
    );

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Remove saved connection'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(find.text('delete.example:5000'), findsNothing);
    expect(find.text('Removed delete.example:5000'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    expect(app.savedNetworkConnections, isEmpty);
    expect(await tester.runAsync(() => store.load()), isEmpty);

    await tester.runAsync(() async {
      await tester.tap(find.text('Undo'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(find.text('delete.example:5000'), findsOneWidget);
    final restored = await tester.runAsync(() => store.load());
    expect(restored, hasLength(1));
    expect(restored!.single.displayAddress, 'delete.example:5000');
    expect(restored.single.lastConnectedAt, original.lastConnectedAt);
  });

  testWidgets('tapping a saved card connects and pops only on success',
      (tester) async {
    final original = _recentConnection('192.168.1.55');
    final store = _historyStore(dir);
    await tester.runAsync(() => store.save([original]));
    final fake = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    var attempts = 0;
    final app = await pumpScreen(
      tester,
      _networkCapabilities,
      networkStore: store,
      tcpLinkFactory: (host, port, onLog) {
        attempts++;
        return fake;
      },
      push: true,
    );

    await tester.runAsync(() async {
      await tester.tap(find.text('192.168.1.55:5000'));
      while (app.busy) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(attempts, 1);
    expect(find.text('open connect'), findsOneWidget);
    expect(app.deviceConnected, isTrue, reason: app.logs.join('\n'));
    final saved = app.savedNetworkConnections.single;
    expect(saved.host, '192.168.1.55');
    expect(saved.port, 5000);
    expect(saved.lastConnectedAt, greaterThan(original.lastConnectedAt));
    final persisted = await tester.runAsync(() => store.load());
    expect(persisted!.single.lastConnectedAt, saved.lastConnectedAt);
  });

  testWidgets('a failed saved-card attempt keeps the screen and values',
      (tester) async {
    final original = _recentConnection('192.168.1.55');
    final store = _historyStore(dir);
    await tester.runAsync(() => store.save([original]));
    final fake = FakeDeviceLink()
      ..deviceInfoError =
          const DeviceCommandError.malformed(message: 'device unavailable');
    final app = await pumpScreen(
      tester,
      _networkCapabilities,
      networkStore: store,
      tcpLinkFactory: (host, port, onLog) => fake,
      push: true,
    );

    await tester.runAsync(() async {
      await tester.tap(find.text('192.168.1.55:5000'));
      while (app.busy) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(find.byType(ConnectScreen), findsOneWidget);
    expect(
      find.text(
        'Could not connect to 192.168.1.55:5000. See the log for details.',
      ),
      findsOneWidget,
    );
    final fields =
        tester.widgetList<TextFormField>(find.byType(TextFormField)).toList();
    expect(fields[0].controller!.text, '192.168.1.55');
    expect(fields[1].controller!.text, '5000');
    expect(app.savedNetworkConnections.single, original);
  });

  testWidgets('invalid host and port show errors without connecting',
      (tester) async {
    var attempts = 0;
    final app = await pumpScreen(
      tester,
      _networkCapabilities,
      tcpLinkFactory: (host, port, onLog) {
        attempts++;
        return FakeDeviceLink();
      },
    );

    await tester.enterText(find.byType(TextFormField).at(0), '   ');
    await tester.enterText(find.byType(TextFormField).at(1), '70000');
    await tester.tap(find.text('Connect over TCP'));
    await tester.pump();

    expect(find.text('Enter a host'), findsOneWidget);
    expect(find.text('Enter a port between 1 and 65535'), findsOneWidget);
    expect(attempts, 0);
    expect(app.deviceConnected, isFalse);
  });

  testWidgets('the connected banner stays above the tabs while switching',
      (tester) async {
    final app = await pumpScreen(tester, _simulatedCapabilities);

    await tester.runAsync(() => app.connectSimulated());
    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(find.text('Simulated companion'), findsOneWidget);

    await tester.tap(find.text('Simulated'));
    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(find.text('Simulated companion'), findsNWidgets(2));
  });

  testWidgets('a busy connection disables actions but keeps tabs usable',
      (tester) async {
    final store = _historyStore(dir);
    await tester
        .runAsync(() => store.save([_recentConnection('192.168.1.55')]));
    final app = await pumpScreen(
      tester,
      _simulatedCapabilities,
      networkStore: store,
    );

    app.busy = true;
    app.log('test: hold busy');
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    final connect = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Connect over TCP'),
    );
    expect(connect.onPressed, isNull);
    final delete = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.delete_outline),
    );
    expect(delete.onPressed, isNull);

    await tester.tap(find.text('Simulated'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Simulated companion'), findsOneWidget);
    final simulatedButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Connect simulated companion'),
    );
    expect(simulatedButton.onPressed, isNull);

    app.busy = false;
    app.log('test: release busy');
    await tester.pump();
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

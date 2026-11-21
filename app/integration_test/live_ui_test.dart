// Linux desktop UI test against a real TCP companion.
//
//   flutter test integration_test/live_ui_test.dart -d linux \
//     --dart-define=DEVICE_HOST=<host> [--dart-define=DEVICE_PORT=5000]
//
// Drives the real HomeScreen/ConnectScreen/IdentitiesScreen/DiagnosticsScreen
// against AppState and a live companion. It never transmits on the mesh.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:device_link/device_link.dart';
import 'package:test_support/test_support.dart' as support;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/screens/home_screen.dart';
import 'package:meshchameleon/screens/connect_screen.dart';
import 'package:meshchameleon/screens/diagnostics_screen.dart';
import 'package:meshchameleon/screens/identities_screen.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/network_connection_store.dart';
import 'package:meshchameleon/services/session_store.dart';
import 'package:provider/provider.dart';

const _deviceHost = String.fromEnvironment('DEVICE_HOST');
const _devicePort = int.fromEnvironment('DEVICE_PORT', defaultValue: 5000);

class _Client extends support.FramedClient {
  _Client(super.socket);

  @override
  @override
  Future<Uint8List> next({
    bool pushes = false,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    while (true) {
      final frame = await super.next(timeout: timeout);
      if (frame.isNotEmpty && frame[0] >= 0x80) continue;
      return frame;
    }
  }

  Future<Uint8List> command(List<int> payload) async {
    send(payload);
    return next();
  }

  Future<Uint8List> handshake() async {
    expect((await command([cmdDeviceQuery, appProtocolVersion]))[0],
        respCodeDeviceInfo);
    send([
      cmdAppStart,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      ...utf8.encode('LIVE-UI'),
      0,
    ]);
    final frame = await next();
    expect(frame[0], respCodeSelfInfo);
    return frame;
  }
}

Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 25),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'condition not met before $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
}

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await Future<void>.delayed(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

Finder identityTile(String name) => find.widgetWithText(ListTile, name);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real Linux UI connects, serves, and manages identities',
      (tester) async {
    if (_deviceHost.isEmpty) {
      fail('Set DEVICE_HOST to the companion TCP host.');
    }
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    FlutterSecureStorage.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('mesh_ui_live_');
    final app = AppState(
      repository: IdentityRepository(
        supportDirectory: dir,
        secureStore: IdentityStore(),
      ),
      sessionStore: SessionStore(file: File('${dir.path}/session.json')),
      networkConnectionStore:
          NetworkConnectionStore(file: File('${dir.path}/history.json')),
      capabilities: const DeviceCapabilities(supportsBle: false),
      reconnectDelay: const Duration(milliseconds: 300),
    );
    _Client? client;
    addTearDown(() async {
      await client?.close();
      await app.disconnectDevice();
      await app.manager?.dispose();
      await dir.delete(recursive: true);
    });
    await app.loadIdentities();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppViewState>.value(
        value: app,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await settle(tester);
    expect(find.text('MeshChameleon'), findsWidgets);
    expect(app.identities, hasLength(1));

    // Set a non-default proxy port through Settings.
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    await tester.tap(find.text('Proxy server port'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), '15321');
    await tester.tap(find.text('Save port'));
    await settle(tester);
    expect(app.port, 15321);
    await tester.pageBack();
    await settle(tester);

    // Open the real ConnectScreen and attach the live companion.
    await tester.tap(find.text('Device link'));
    await settle(tester);
    expect(find.byType(ConnectScreen), findsOneWidget);
    final fields =
        tester.widgetList<TextFormField>(find.byType(TextFormField)).toList();
    fields[0].controller!.text = _deviceHost;
    fields[1].controller!.text = '$_devicePort';
    await tester.pump();
    await tester.tap(find.text('Connect over TCP'));
    await pumpUntil(tester, () => app.deviceConnected,
        reason: 'live TCP attach failed:\n${app.logs.join('\n')}');
    await settle(tester);
    expect(find.byType(ConnectScreen), findsNothing);
    expect(
        find.textContaining('TCP $_deviceHost:$_devicePort'), findsOneWidget);
    expect(app.activeIdentity!.live, isTrue);

    // Start the proxy from the switch and handshake as a MeshCore client.
    await tester.tap(find.widgetWithText(SwitchListTile, 'Proxy server'));
    await pumpUntil(tester, () => app.proxyStatus == ProxyStatus.running,
        reason: 'proxy did not start:\n${app.logs.join('\n')}');
    await settle(tester);
    expect(find.text('Listening on port 15321'), findsOneWidget);
    client = _Client(await Socket.connect('127.0.0.1', app.port));
    final firstSelf = ParsedSelfInfo.parse(await client.handshake());
    expect(firstSelf, isNotNull);
    expect(firstSelf!.publicKey, app.identity!.publicKey);

    // The live companion's read-only surface is available through the proxy.
    final battery = await client.command([cmdGetBattAndStorage]);
    expect(battery[0], respCodeBattAndStorage);
    final stats = await client.command([cmdGetStats, statsTypePackets]);
    expect(stats[0], respCodeStats);
    final core = await client.command([cmdGetStats, statsTypeCore]);
    expect(core[0], respCodeStats);

    // Saved history is visible, removable, and restorable in the real UI.
    await tester.tap(find.text('Device link'));
    await settle(tester);
    expect(find.text('$_deviceHost:$_devicePort'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove saved connection'));
    await pumpUntil(tester, () => app.savedNetworkConnections.isEmpty,
        reason: 'saved connection was not removed');
    await settle(tester);
    expect(find.text('Undo'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await pumpUntil(tester, () => app.savedNetworkConnections.length == 1,
        reason: 'saved connection was not restored');
    await settle(tester);
    expect(find.text('$_deviceHost:$_devicePort'), findsOneWidget);
    await tester.pageBack();
    await settle(tester);

    Future<void> openIdentityManagement() async {
      await tester.tap(find.text('Switch'));
      await settle(tester);
      await tester.tap(find.text('Manage identities'));
      await settle(tester);
    }

    // Create an inactive identity through the real dialog.
    await openIdentityManagement();
    await settle(tester);
    expect(find.byType(IdentitiesScreen), findsOneWidget);
    await tester.tap(find.text('Create identity'));
    await settle(tester);
    expect(find.text('New identity'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'UI Second');
    await tester.tap(find.text('Create'));
    await pumpUntil(tester, () => app.identities.length == 2,
        reason: 'identity was not created');
    await settle(tester);
    final created =
        app.identities.firstWhere((item) => item.name == 'UI Second');
    expect(created.active, isFalse);
    expect(created.live, isTrue, reason: app.logs.join('\n'));

    // Disable and re-enable the inactive identity from its menu.
    Finder menuFor(String name) => find.descendant(
          of: find.ancestor(
            of: find.text(name),
            matching: find.byType(Card),
          ),
          matching: find.byType(PopupMenuButton<String>),
        );
    await tester.tap(menuFor('UI Second'));
    await settle(tester);
    await tester.tap(find.text('Disable identity'));
    await pumpUntil(
      tester,
      () =>
          app.identities
              .firstWhere((item) => item.name == 'UI Second')
              .enabled ==
          false,
      reason: 'identity was not disabled',
    );
    await settle(tester);
    var second = app.identities.firstWhere((item) => item.name == 'UI Second');
    expect(second.live, isFalse);
    await tester.tap(menuFor('UI Second'));
    await settle(tester);
    await tester.tap(find.text('Enable identity'));
    await pumpUntil(
      tester,
      () =>
          app.identities
              .firstWhere((item) => item.name == 'UI Second')
              .enabled ==
          true,
      reason: 'identity was not re-enabled',
    );
    await settle(tester);

    // Activate it: the old client is disconnected and SELF_INFO changes.
    await tester.tap(identityTile('UI Second'));
    await pumpUntil(tester, () => app.activeIdentity!.name == 'UI Second',
        reason: 'identity was not activated');
    await settle(tester);
    expect(find.byType(IdentitiesScreen), findsNothing);
    // The swap disconnects the old client; reconnect and check SELF_INFO.
    try {
      await client.close();
    } catch (_) {}
    client = _Client(await Socket.connect('127.0.0.1', app.port));
    final secondSelf = ParsedSelfInfo.parse(await client.handshake());
    expect(secondSelf, isNotNull);
    expect(secondSelf!.publicKey, app.identity!.publicKey);
    expect(secondSelf.nodeName, 'UI Second');

    // Diagnostics shows the live session and both identities.
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    await tester.ensureVisible(find.text('Information'));
    await tester.tap(find.text('Information'));
    await settle(tester);
    expect(find.byType(DiagnosticsScreen), findsOneWidget);
    expect(find.text('Connected'), findsWidgets);
    expect(find.text('UI Second'), findsOneWidget);
    expect(find.text(app.activeIdentity!.name), findsWidgets);
    await tester.pageBack();
    await settle(tester);
    await tester.pageBack();
    await settle(tester);

    // Clear local data on the active identity and keep key/name.
    await openIdentityManagement();
    await tester.tap(menuFor('UI Second'));
    await settle(tester);
    await tester.tap(find.text('Clear local data'));
    await settle(tester);
    await tester.tap(find.text('Clear'));
    await pumpUntil(
      tester,
      () =>
          app.identities
              .firstWhere((item) => item.name == 'UI Second')
              .contactCount ==
          0,
      reason: 'clear local data did not complete',
    );
    await settle(tester);
    second = app.identities.firstWhere((item) => item.name == 'UI Second');
    expect(second.name, 'UI Second');
    expect(second.keyAvailable, isTrue);

    // Delete the inactive first identity after switching back.
    final firstName = app.identities.firstWhere((item) => !item.active).name;
    await tester.tap(identityTile(firstName));
    await pumpUntil(tester, () => app.activeIdentity!.name == firstName,
        reason: 'could not activate the first identity');
    await settle(tester);
    await openIdentityManagement();
    await tester.tap(menuFor('UI Second'));
    await settle(tester);
    await tester.tap(find.text('Delete identity'));
    await settle(tester);
    await tester.tap(find.text('Delete'));
    await pumpUntil(tester, () => app.identities.length == 1,
        reason: 'identity was not deleted');
    await settle(tester);
    expect(app.identities.single.name, firstName);

    // Backup/restore through the real service while the UI is still mounted.
    final backup =
        await tester.runAsync(() => app.createBackup('passphrase-123'));
    expect(backup, isNotNull);
    final preview = await tester
        .runAsync(() => app.inspectBackup(backup!, 'passphrase-123'));
    expect(preview, isNotNull);
    expect(preview!.identityCount, 1);
    final restored = await tester.runAsync(() => app.restoreBackup(preview));
    expect(restored, isTrue, reason: app.logs.join('\n'));
    await settle(tester);
    expect(app.identities, hasLength(1));
    expect(app.deviceConnected, isFalse);
    expect(app.proxyStatus, ProxyStatus.stopped);

    // Turn Resume on, then verify a fresh AppState restores the last session.
    await app.setAutoResume(true);
    await app.connectTcp(host: _deviceHost, tcpPort: _devicePort);
    expect(app.deviceConnected, isTrue);
    await app.startProxy();
    final resumedPort = app.port;
    await app.disconnectDevice();
    final resumed = AppState(
      repository: IdentityRepository(
        supportDirectory: dir,
        secureStore: IdentityStore(),
      ),
      sessionStore: SessionStore(file: File('${dir.path}/session.json')),
      networkConnectionStore:
          NetworkConnectionStore(file: File('${dir.path}/history.json')),
      capabilities: const DeviceCapabilities(supportsBle: false),
      reconnectDelay: const Duration(milliseconds: 300),
    );
    addTearDown(() async {
      await resumed.disconnectDevice();
      await resumed.manager?.dispose();
    });
    await resumed.loadIdentities();
    await pumpUntil(tester, () => resumed.deviceConnected,
        reason: 'auto-resume did not reconnect:\n${resumed.logs.join('\n')}');
    await pumpUntil(tester, () => resumed.proxyStatus == ProxyStatus.running,
        reason: 'auto-resume did not start the proxy');
    expect(resumed.port, resumedPort);
    await resumed.disconnectDevice();
  });
}

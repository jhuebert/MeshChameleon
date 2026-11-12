// Opt-in render fixtures for the UI review checkpoint. See
// docs/UI_OVERHAUL_PLAN.md; these are not Android validation or goldens.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/app_route_observer.dart';
import 'package:meshchameleon/app_view_state.dart';
import 'package:meshchameleon/screens/about_screen.dart';
import 'package:meshchameleon/screens/home_screen.dart';
import 'package:meshchameleon/screens/settings_screen.dart';
import 'package:meshchameleon/theme/app_theme.dart';
import 'package:provider/provider.dart';

import 'support/fake_app_state.dart';

final outputDirectory = Platform.environment['UI_REVIEW_OUTPUT'];

IdentitySummary identity(String id, String name, int firstByte,
        {required bool active, required bool live, int waiting = 0}) =>
    IdentitySummary(
      id: id,
      name: name,
      publicKey: Uint8List(32)..[0] = firstByte,
      createdAt: 1,
      active: active,
      live: live,
      keyAvailable: true,
      channelCount: 2,
      contactCount: 4,
      queuedDirect: waiting,
      queuedChannel: 0,
    );

FakeAppState fixture({bool connected = false, bool waiting = false}) {
  final active = identity('a', 'Trail Crew', 0x5d,
      active: true, live: connected, waiting: 2);
  final other = identity('b', 'Field Team', 0x4a,
      active: false, live: connected, waiting: 1);
  final app = FakeAppState()
    ..summaries = [active, other]
    ..activeSummary = active
    ..deviceConnected = connected
    ..deviceWaiting = waiting
    ..deviceLabel = connected || waiting ? 'MeshCore Example' : null
    ..lastSession = const SessionConfig(kind: DeviceTargetKind.ble)
    ..proxyStatus = connected ? ProxyStatus.running : ProxyStatus.stopped
    ..phoneBatteryPercent = 78
    ..gpsScope = connected
        ? const GpsScope(
            identityId: 'a',
            identityName: 'Trail Crew',
            requested: false,
            configuredIntervalSeconds: 900,
          )
        : null;
  if (connected) {
    app.companionMetricsValue.recordClientConnected(null);
    app.linkMetricsValue.rawTxPackets = 128;
    app.linkMetricsValue.rawRxPackets = 342;
    app.radioHealth = RadioHealth(
      millivolts: 3910,
      storageUsedKb: 512,
      storageTotalKb: 4096,
      sampledAt: DateTime.utc(2026, 11, 11),
    );
  }
  return app;
}

void main() {
  testWidgets('capture synthetic UI review fixtures', (tester) async {
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    if (flutterRoot == null) throw StateError('Set FLUTTER_ROOT for Roboto');
    await tester.runAsync(() async {
      final fonts = FontLoader('Roboto');
      for (final weight in ['Regular', 'Medium', 'Bold']) {
        final bytes = File('$flutterRoot/bin/cache/dart-sdk/bin/resources/'
                'devtools/assets/fonts/Roboto/Roboto-$weight.ttf')
            .readAsBytesSync();
        fonts.addFont(Future.value(ByteData.sublistView(bytes)));
      }
      await fonts.load();
      final mono = FontLoader('monospace');
      final monoBytes = File('$flutterRoot/bin/cache/dart-sdk/bin/resources/'
              'devtools/assets/fonts/Roboto_Mono/RobotoMono-Regular.ttf')
          .readAsBytesSync();
      mono.addFont(Future.value(ByteData.sublistView(monoBytes)));
      await mono.load();
      final icons = FontLoader('MaterialIcons');
      final iconBytes = File('$flutterRoot/bin/cache/artifacts/material_fonts/'
              'MaterialIcons-Regular.otf')
          .readAsBytesSync();
      icons.addFont(Future.value(ByteData.sublistView(iconBytes)));
      await icons.load();
    });

    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundaryKey = GlobalKey();
    final directory = Directory(outputDirectory!);
    directory.createSync(recursive: true);

    Future<void> capture(String name, FakeAppState app, Widget screen,
        {bool light = false, double scale = 1, bool sheet = false}) async {
      final theme =
          light ? MeshChameleonTheme.light() : MeshChameleonTheme.dark();
      await tester.pumpWidget(RepaintBoundary(
        key: boundaryKey,
        child: ChangeNotifierProvider<AppViewState>.value(
          value: app,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
              listTileTheme: theme.listTileTheme.copyWith(
                subtitleTextStyle: theme.listTileTheme.subtitleTextStyle
                    ?.copyWith(fontFamily: 'Roboto'),
              ),
            ),
            navigatorObservers: [appRouteObserver],
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: screen,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.runAsync(() => precacheImage(
            const AssetImage('assets/branding/icon.png'),
            boundaryKey.currentContext!,
          ));
      await tester.pump();
      if (sheet) {
        await tester.tap(find.text('Switch').first);
        await tester.pumpAndSettle();
      }
      final boundary = boundaryKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${directory.path}/$name.png')
            .writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    }

    for (final light in [false, true]) {
      final mode = light ? 'light' : 'dark';
      await capture('home-idle-$mode', fixture(), const HomeScreen(),
          light: light);
      await capture(
          'home-connected-$mode', fixture(connected: true), const HomeScreen(),
          light: light);
      await capture(
          'settings-$mode', fixture(connected: true), const SettingsScreen(),
          light: light);
      await capture('about-$mode', fixture(), const AboutScreen(),
          light: light);
    }
    await capture(
        'home-waiting-dark', fixture(waiting: true), const HomeScreen());
    await capture('switcher-dark', fixture(connected: true), const HomeScreen(),
        sheet: true);
    await capture(
        'home-large-text-dark', fixture(connected: true), const HomeScreen(),
        scale: 2);
    await capture('settings-large-text-dark', fixture(connected: true),
        const SettingsScreen(),
        scale: 2);
  }, skip: outputDirectory == null);
}

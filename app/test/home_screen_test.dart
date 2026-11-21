import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/app_route_observer.dart';
import 'package:meshchameleon/app_view_state.dart';
import 'package:meshchameleon/screens/diagnostics_screen.dart';
import 'package:meshchameleon/screens/home_screen.dart';
import 'package:meshchameleon/theme/app_theme.dart';
import 'package:provider/provider.dart';

import 'support/fake_app_state.dart';

IdentitySummary _homeSummary({
  bool live = true,
  bool active = true,
  bool enabled = true,
  bool keyAvailable = true,
  String? unavailableReason,
  String name = 'Home Identity',
  int queuedDirect = 0,
  int queuedChannel = 0,
  int contactCount = 2,
  int channelCount = 1,
}) =>
    IdentitySummary(
      id: 'a' * 32,
      name: name,
      publicKey: Uint8List(32)..[0] = 0xAB,
      createdAt: 1,
      active: active,
      live: live,
      keyAvailable: keyAvailable,
      channelCount: channelCount,
      contactCount: contactCount,
      queuedDirect: queuedDirect,
      queuedChannel: queuedChannel,
      enabled: enabled,
      unavailableReason: unavailableReason,
    );

Future<void> _pumpHome(
  WidgetTester tester,
  FakeAppState app, {
  double textScale = 1.0,
}) {
  return tester.pumpWidget(
    ChangeNotifierProvider<AppViewState>.value(
      value: app,
      child: MaterialApp(
        theme: MeshChameleonTheme.dark(),
        themeMode: ThemeMode.dark,
        navigatorObservers: [appRouteObserver],
        builder: textScale == 1.0
            ? null
            : (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(textScale)),
                  child: child!,
                ),
        home: const HomeScreen(),
      ),
    ),
  );
}

void _setView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _setTallView(WidgetTester tester) => _setView(
      tester,
      const Size(1200, 3000),
    );

/// Captures Clipboard.setData payloads sent through the platform channel.
class _ClipboardSpy {
  String? text;

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          text = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
  }
}

void main() {
  testWidgets('home exposes labeled Android-sized touch targets',
      (tester) async {
    _setView(tester, const Size(360, 800));
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary
      ..deviceConnected = true;
    final semantics = tester.ensureSemantics();
    await _pumpHome(tester, app);
    await tester.pump();
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    semantics.dispose();
  });

  testWidgets('essential controls are visible on a 360x800 phone',
      (tester) async {
    _setView(tester, const Size(360, 800));
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary
      ..deviceConnected = true
      ..deviceLabel = 'MeshCore-nc3'
      ..proxyStatus = ProxyStatus.running
      ..port = 5000;

    await _pumpHome(tester, app);
    await tester.pump();

    const bottom = 800.0;
    for (final finder in [
      find.text('Home Identity'),
      find.text('Device link'),
      find.text('Proxy server'),
      find.byTooltip('Copy endpoint'),
    ]) {
      expect(finder, findsOneWidget);
      expect(tester.getTopLeft(finder).dy, lessThan(bottom),
          reason: '$finder must be visible without scrolling');
      expect(tester.getBottomLeft(finder).dy, lessThanOrEqualTo(bottom));
    }
  });

  testWidgets('at 320px and 2.0x text scale everything stays reachable',
      (tester) async {
    _setView(tester, const Size(320, 800));
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary
      ..deviceConnected = true
      ..deviceLabel = 'MeshCore-nc3'
      ..proxyStatus = ProxyStatus.running
      ..port = 5000;

    await _pumpHome(tester, app, textScale: 2.0);
    await tester.pump();

    await tester.scrollUntilVisible(
      find.text('Radio activity'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    // The affordance collapses to an icon-only chevron at high text scales.
    expect(find.text('Show details'), findsNothing);
    await tester.ensureVisible(find.text('Radio activity'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Radio activity'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Not received yet'), findsWidgets);

    await tester.scrollUntilVisible(
      find.byTooltip('Copy endpoint'),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byTooltip('Copy endpoint'), findsOneWidget);
  });

  testWidgets('loading state shows a placeholder, never an empty state',
      (tester) async {
    _setTallView(tester);
    final app = FakeAppState()..loaded = false;
    await _pumpHome(tester, app);
    await tester.pump();

    expect(find.text('Loading identities…'), findsOneWidget);
    expect(find.text('No identities yet'), findsNothing);
    expect(find.text('Create identity'), findsNothing);
  });

  testWidgets('database error shows recovery paths and never silently resets',
      (tester) async {
    _setTallView(tester);
    final app = FakeAppState()..dbError = 'corrupt catalog';
    await _pumpHome(tester, app);
    await tester.pump();

    expect(find.text('Identity database unavailable'), findsOneWidget);
    expect(find.text('Loading identities…'), findsNothing);
    expect(find.text('No identities yet'), findsNothing);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(app.loadCalls, greaterThanOrEqualTo(1));
  });

  testWidgets('genuinely empty catalog offers creation', (tester) async {
    _setTallView(tester);
    final app = FakeAppState()..summaries = [];
    await _pumpHome(tester, app);
    await tester.pump();

    expect(find.text('No identities yet'), findsOneWidget);
    expect(find.text('Create identity'), findsOneWidget);
  });

  testWidgets('unavailable active identity offers management, not a green Live',
      (tester) async {
    _setTallView(tester);
    final summary = _homeSummary(live: false, keyAvailable: false);
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary;
    await _pumpHome(tester, app);
    await tester.pump();

    expect(find.text('Live'), findsNothing);
    expect(find.textContaining('Key unavailable'), findsWidgets);
    expect(
        find.widgetWithText(FilledButton, 'Manage identities'), findsOneWidget);
    expect(
        find.widgetWithText(OutlinedButton, 'Switch identity'), findsOneWidget);
  });

  testWidgets('an available offline identity remains selectable',
      (tester) async {
    _setTallView(tester);
    final summary = _homeSummary(live: false);
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary;
    await _pumpHome(tester, app);
    await tester.pump();

    expect(find.textContaining('#AB000000 · Offline'), findsOneWidget);
    expect(find.text('Switch'), findsOneWidget);
    expect(find.textContaining('This identity cannot start'), findsNothing);
  });

  testWidgets('identity card shows name, prefix, contacts and queue',
      (tester) async {
    _setTallView(tester);
    final summary =
        _homeSummary(queuedDirect: 2, queuedChannel: 1, contactCount: 4);
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary;
    await _pumpHome(tester, app);
    await tester.pump();

    expect(find.text('Home Identity'), findsOneWidget);
    expect(find.textContaining('#AB000000 · Live'), findsOneWidget);
    expect(find.textContaining('4 contacts'), findsOneWidget);
    expect(find.text('3 waiting to sync'), findsOneWidget);
  });

  testWidgets('zero queue says so plainly', (tester) async {
    _setTallView(tester);
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary;
    await _pumpHome(tester, app);
    await tester.pump();

    expect(find.text('No messages waiting to sync'), findsOneWidget);
  });

  testWidgets('other-identity queues are reported separately', (tester) async {
    _setTallView(tester);
    final active = _homeSummary();
    final other = IdentitySummary(
      id: 'b' * 32,
      name: 'Field',
      publicKey: Uint8List(32)..[0] = 0xCD,
      createdAt: 2,
      active: false,
      live: true,
      keyAvailable: true,
      channelCount: 0,
      contactCount: 0,
      queuedDirect: 3,
      queuedChannel: 1,
    );
    final app = FakeAppState()
      ..summaries = [active, other]
      ..activeSummary = active;
    await _pumpHome(tester, app);
    await tester.pump();

    expect(find.text('4 waiting on other identities'), findsOneWidget);
    expect(find.text('No messages waiting to sync'), findsOneWidget);
  });

  testWidgets('proxy switch reflects listener state and stops a running proxy',
      (tester) async {
    _setTallView(tester);
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary
      ..deviceConnected = true
      ..deviceLabel = 'MeshCore-nc3'
      ..proxyStatus = ProxyStatus.running
      ..port = 5000;
    await _pumpHome(tester, app);
    await tester.pump();

    expect(find.text('Listening on port 5000'), findsOneWidget);
    await tester.tap(find.widgetWithText(SwitchListTile, 'Proxy server'));
    await tester.pump();
    expect(app.stopProxyCalls, 1);
    expect(app.proxyStatus, ProxyStatus.stopped);
  });

  testWidgets('proxy switch is disabled with a reason when the radio is idle',
      (tester) async {
    _setTallView(tester);
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary;
    await _pumpHome(tester, app);
    await tester.pump();

    final proxySwitch = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Proxy server'),
    );
    expect(proxySwitch.onChanged, isNull);
    expect(find.textContaining('Connect a radio to start the proxy'),
        findsOneWidget);
  });

  testWidgets('failed proxy start keeps the switch truthful with retry',
      (tester) async {
    _setTallView(tester);
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary
      ..deviceConnected = true
      ..deviceLabel = 'MeshCore-nc3'
      ..startProxyResult = false;
    await _pumpHome(tester, app);
    await tester.pump();

    await tester.tap(find.widgetWithText(SwitchListTile, 'Proxy server'));
    await tester.pump();

    expect(app.proxyStatus, ProxyStatus.stopped);
    expect(find.textContaining('Could not start the proxy'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, 'Proxy server'),
          )
          .value,
      isFalse,
    );

    app.startProxyResult = true;
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pump();
    expect(app.proxyStatus, ProxyStatus.running);
    expect(find.textContaining('Could not start the proxy'), findsNothing);
  });

  testWidgets('reconnecting state cancels recovery', (tester) async {
    _setTallView(tester);
    final app = FakeAppState()
      ..deviceConnected = true
      ..deviceReconnecting = true
      ..deviceLabel = 'MeshCore-nc3';
    await _pumpHome(tester, app);
    await tester.pump();

    expect(find.textContaining('Reconnecting…'), findsOneWidget);
    expect(find.text('Disconnect'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(app.cancelCalls, 1);
  });

  testWidgets('waiting state keeps the parked proxy and cancellation clear',
      (tester) async {
    _setTallView(tester);
    final app = FakeAppState()
      ..phase = DeviceLinkPhase.waiting
      ..deviceWaiting = true
      ..deviceLabel = 'MeshCore-nc3';
    await _pumpHome(tester, app);
    await tester.pump();

    expect(find.textContaining('Waiting for MeshCore-nc3'), findsOneWidget);
    expect(find.textContaining('Waiting for the companion to return'),
        findsNothing);
    expect(find.textContaining('Waiting for the radio'), findsOneWidget);

    final proxySwitch = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Proxy server'),
    );
    expect(proxySwitch.onChanged, isNull);

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(app.cancelCalls, 1);
  });

  testWidgets('connecting offers Cancel, never Disconnect', (tester) async {
    _setTallView(tester);
    final app = FakeAppState()
      ..phase = DeviceLinkPhase.connecting
      ..deviceConnecting = true
      ..deviceLabel = 'TCP radio.local:5000';
    await _pumpHome(tester, app);
    await tester.pump();

    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Disconnect'), findsNothing);
  });

  testWidgets('Copy endpoint copies the configured host:port', (tester) async {
    _setTallView(tester);
    final spy = _ClipboardSpy()..install(tester);
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary
      ..proxyStatus = ProxyStatus.running
      ..port = 8123;
    await _pumpHome(tester, app);
    await tester.pump();

    await tester.tap(find.byTooltip('Copy endpoint'));
    await tester.pump();

    expect(spy.text, '127.0.0.1:8123');
    expect(find.text('Endpoint copied'), findsOneWidget);
  });

  testWidgets('client row distinguishes stopped, waiting, and connected',
      (tester) async {
    _setTallView(tester);
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary
      ..proxyStatus = ProxyStatus.running
      ..port = 5000;
    await _pumpHome(tester, app);
    await tester.pump();

    expect(find.text('Waiting for app'), findsOneWidget);
    expect(find.textContaining('Client address'), findsNothing);

    app.companionMetricsValue.recordClientConnected('10.0.0.9:41234');
    app.notifyListeners();
    await tester.pump(const Duration(seconds: 5));

    expect(find.text('Connected'), findsOneWidget);
    expect(
        find.textContaining('Client address: 10.0.0.9:41234'), findsOneWidget);
  });

  testWidgets('proxy stopped reports Server stopped, endpoint stays copyable',
      (tester) async {
    _setTallView(tester);
    final spy = _ClipboardSpy()..install(tester);
    final app = FakeAppState()..port = 5000;
    await _pumpHome(tester, app);
    await tester.pump();

    expect(find.text('Server stopped'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy endpoint'));
    await tester.pump();
    expect(spy.text, '127.0.0.1:5000');
  });

  testWidgets('radio activity expands to show signal and sample age',
      (tester) async {
    _setTallView(tester);
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary
      ..deviceConnected = true
      ..deviceLabel = 'MeshCore-nc3'
      ..proxyStatus = ProxyStatus.running
      ..radioHealth = RadioHealth(
        millivolts: 3910,
        storageUsedKb: 512,
        storageTotalKb: 4096,
        sampledAt: DateTime.now().subtract(const Duration(seconds: 45)),
      );
    app.linkMetricsValue.connectionSucceeded();
    app.linkMetricsValue.rawRx(6.5, -72, 42);
    await _pumpHome(tester, app);
    await tester.pump();

    expect(find.text('3.91 V'), findsOneWidget);
    expect(find.text('Not received yet'), findsNothing);

    await tester.tap(find.text('Show details'));
    await tester.pump();

    expect(find.textContaining('-72 dBm'), findsOneWidget);
    expect(find.textContaining('6.5 dB SNR'), findsOneWidget);
    expect(find.textContaining('Updated 45s ago'), findsOneWidget);
    expect(find.textContaining('512 of 4,096 KiB'), findsOneWidget);
    expect(find.text('Hide details'), findsOneWidget);
  });

  testWidgets('no radio connected shows the label, totals stay visible',
      (tester) async {
    _setTallView(tester);
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary;
    await _pumpHome(tester, app);
    await tester.pump();

    expect(find.text('No radio connected'), findsOneWidget);
    expect(find.text('TX packets'), findsOneWidget);
    expect(find.textContaining('Packet totals since app opened'), findsNothing);
  });

  testWidgets('no sample reads Unavailable, never 0 V', (tester) async {
    _setTallView(tester);
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary
      ..deviceConnected = true;
    await _pumpHome(tester, app);
    await tester.pump();

    expect(find.text('—'), findsOneWidget);
    expect(find.textContaining('0.00 V'), findsNothing);
  });

  testWidgets('a real zero-voltage sample is distinct from no sample',
      (tester) async {
    _setTallView(tester);
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary
      ..deviceConnected = true
      ..radioHealth = RadioHealth(
        millivolts: 0,
        storageUsedKb: 10,
        storageTotalKb: 0,
        sampledAt: DateTime.now(),
      );
    await _pumpHome(tester, app);
    await tester.pump();
    expect(find.text('0.00 V'), findsOneWidget);
    await tester.tap(find.text('Show details'));
    await tester.pump();
    expect(find.text('Unavailable'), findsOneWidget);
  });

  testWidgets('signal unreceived reads Not received yet', (tester) async {
    _setTallView(tester);
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary
      ..deviceConnected = true;
    await _pumpHome(tester, app);
    await tester.pump();

    await tester.tap(find.text('Show details'));
    await tester.pump();
    expect(find.text('Not received yet'), findsNWidgets(2));
  });

  testWidgets('old reception is not shown as the current radio signal',
      (tester) async {
    _setTallView(tester);
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary
      ..deviceConnected = true;
    app.linkMetricsValue.connectionSucceeded();
    app.linkMetricsValue.rawRx(4, -80, 10);
    await _pumpHome(tester, app);
    await tester.pump();
    await tester.tap(find.text('Show details'));
    await tester.pump();
    expect(find.textContaining('-80 dBm'), findsOneWidget);

    app.linkMetricsValue.disconnected();
    app.linkMetricsValue.connectionSucceeded();
    app.notifyListeners();
    await tester.pump();
    expect(find.textContaining('-80 dBm'), findsNothing);
    expect(find.text('Not received yet'), findsNWidgets(2));
    expect(app.linkMetricsValue.rawRxPackets, 1);
    expect(app.linkMetricsValue.lastRssi, -80);
  });

  testWidgets('simulated sessions are labeled as simulated', (tester) async {
    _setTallView(tester);
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary
      ..deviceConnected = true
      ..deviceLabel = 'Simulated companion'
      ..lastSession = SessionConfig(
        kind: DeviceTargetKind.simulated,
        devicePort: 5000,
      );
    await _pumpHome(tester, app);
    await tester.pump();

    expect(find.text('Simulated · no radio traffic'), findsOneWidget);
  });

  testWidgets('battery advice banner shows during active sessions only',
      (tester) async {
    _setTallView(tester);
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary
      ..deviceConnected = true
      ..batteryOptimizationsIgnored = false;
    await _pumpHome(tester, app);
    await tester.pump();

    expect(find.textContaining('Background link may be interrupted'),
        findsOneWidget);
    await tester.tap(find.text('Open settings'));
    await tester.pump();
    expect(app.batteryOpened, 1);

    app.batteryOptimizationsIgnored = true;
    app.notifyListeners();
    await tester.pump();
    expect(find.textContaining('Background link may be interrupted'),
        findsNothing);
  });

  testWidgets('app refresh timer polls while Home is visible', (tester) async {
    _setTallView(tester);
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary
      ..deviceConnected = true;
    await _pumpHome(tester, app);
    await tester.pump();
    final before = app.refreshes;

    await tester.pump(const Duration(seconds: 5));
    expect(app.refreshes, greaterThan(before));
  });

  testWidgets('sampler pauses while another route covers Home', (tester) async {
    _setTallView(tester);
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary
      ..deviceConnected = true;
    await _pumpHome(tester, app);
    await tester.pump();

    await tester.tap(find.byTooltip('Settings'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final covered = app.refreshes;
    await tester.pump(const Duration(seconds: 15));
    expect(app.refreshes, covered, reason: 'no polling while covered');

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump(const Duration(seconds: 5));
    expect(app.refreshes, covered,
        reason: 'resume must not poll under Settings');
    expect(app.rearmCalls, greaterThan(0));

    await tester.pageBack();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(app.refreshes, greaterThan(covered));
  });

  testWidgets('recovery rearm still fires on foreground resume',
      (tester) async {
    _setTallView(tester);
    final app = FakeAppState();
    await _pumpHome(tester, app);
    await tester.pump();
    final before = app.rearmCalls;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(app.rearmCalls, greaterThan(before));
  });

  testWidgets('Information link opens the diagnostics screen', (tester) async {
    _setTallView(tester);
    final summary = _homeSummary();
    final app = FakeAppState()
      ..summaries = [summary]
      ..activeSummary = summary;
    await _pumpHome(tester, app);
    await tester.pump();

    await tester.tap(find.text('Show details'));
    await tester.pump();
    await tester.tap(find.text('Open Information'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(DiagnosticsScreen), findsOneWidget);
    expect(find.text('Information'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/app_view_state.dart';
import 'package:meshchameleon/screens/connect_screen.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/scan_session.dart';
import 'package:provider/provider.dart';

import 'support/fake_app_state.dart';

class FakeScan implements ScanSession {
  final resultController = StreamController<List<ScanResult>>.broadcast();
  final stateController = StreamController<bool>.broadcast();
  bool fail = false;
  int starts = 0;
  int stops = 0;

  @override
  Stream<List<ScanResult>> get results => resultController.stream;
  @override
  Stream<bool> get isScanning => stateController.stream;
  @override
  Future<void> start() async {
    starts++;
    if (fail) throw StateError('denied');
    stateController.add(true);
  }

  @override
  Future<void> stop() async {
    stops++;
    stateController.add(false);
  }
}

void main() {
  testWidgets('scan failure stays visible and permits a retry', (tester) async {
    final scan = FakeScan()..fail = true;
    addTearDown(scan.resultController.close);
    addTearDown(scan.stateController.close);
    await tester.pumpWidget(ChangeNotifierProvider<AppViewState>(
      create: (_) => FakeAppState(),
      child: MaterialApp(
        home: ConnectScreen(
          capabilities: const DeviceCapabilities(supportsBle: true),
          scanSession: scan,
        ),
      ),
    ));
    await tester.tap(find.text('Scan for devices'));
    await tester.pump();
    expect(find.textContaining('Could not start scanning'), findsOneWidget);
    expect(find.text('Rescan'), findsOneWidget);
    scan.fail = false;
    await tester.tap(find.text('Rescan'));
    await tester.pump();
    expect(find.text('Scanning…'), findsOneWidget);
    expect(find.textContaining('Could not start scanning'), findsNothing);
    scan.stateController.add(false);
    await tester.pump();
    expect(find.text('No MeshCore companions found'), findsOneWidget);
  });

  testWidgets('timeout retains results and tab change stops an active scan',
      (tester) async {
    final scan = FakeScan();
    addTearDown(scan.resultController.close);
    addTearDown(scan.stateController.close);
    await tester.pumpWidget(ChangeNotifierProvider<AppViewState>(
      create: (_) => FakeAppState(),
      child: MaterialApp(
        home: ConnectScreen(
          capabilities: const DeviceCapabilities(supportsBle: true),
          scanSession: scan,
        ),
      ),
    ));
    await tester.tap(find.text('Scan for devices'));
    await tester.pump();
    scan.resultController.add([
      ScanResult(
        device: BluetoothDevice.fromId('AA:BB:CC:DD:EE:FF'),
        advertisementData: AdvertisementData(
          advName: 'MeshCore Example',
          txPowerLevel: null,
          appearance: null,
          connectable: true,
          manufacturerData: {},
          serviceData: {},
          serviceUuids: [],
        ),
        rssi: -75,
        timeStamp: DateTime.utc(2026),
      ),
    ]);
    await tester.pump();
    scan.stateController.add(false);
    await tester.pump();
    expect(find.text('MeshCore Example'), findsOneWidget);
    expect(find.text('Bluetooth signal -75 dBm'), findsOneWidget);
    await tester.tap(find.text('Rescan'));
    await tester.pump();
    await tester.tap(find.text('Network'));
    await tester.pumpAndSettle();
    expect(scan.stops, 1);
  });
}

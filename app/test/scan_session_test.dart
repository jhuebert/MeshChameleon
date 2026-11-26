import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/services/scan_session.dart';

void main() {
  test('production scan adapter exposes plugin streams and stop', () async {
    const session = BleScanSession();
    expect(session.results, isNotNull);
    expect(session.isScanning, isNotNull);
    await session.stop();
    // The test environment has no BLE platform implementation; start still
    // delegates to the plugin and reports its failure to the caller.
    var failed = false;
    try {
      await session.start();
    } catch (_) {
      failed = true;
    }
    expect(failed, isTrue);
  });

  test('waits for the adapter before starting the first scan', () async {
    var starts = 0;
    final session = BleScanSession(
      adapterStates: Stream.fromIterable(const [
        BluetoothAdapterState.unknown,
        BluetoothAdapterState.turningOn,
        BluetoothAdapterState.on,
      ]),
      startScan: () async {
        starts++;
      },
    );

    await session.start();

    expect(starts, 1);
  });

  test('a denied permission gives an actionable error', () async {
    final session = BleScanSession(
      adapterStates: Stream.value(BluetoothAdapterState.unauthorized),
      startScan: () async => fail('must not scan without permission'),
    );

    await expectLater(
      session.start(),
      throwsA(
        isA<ScanStartException>().having(
          (e) => e.message,
          'message',
          contains('Privacy & Security'),
        ),
      ),
    );
  });

  test('an off adapter is reported without starting a scan', () async {
    final session = BleScanSession(
      adapterStates: Stream.value(BluetoothAdapterState.off),
      startScan: () async => fail('must not scan with Bluetooth off'),
    );

    await expectLater(
      session.start(),
      throwsA(
        isA<ScanStartException>().having(
          (e) => e.message,
          'message',
          contains('Bluetooth is off'),
        ),
      ),
    );
  });

  test('an adapter that never settles times out with a retry hint', () async {
    final session = BleScanSession(
      adapterStates: Stream.periodic(
        const Duration(milliseconds: 5),
        (_) => BluetoothAdapterState.unknown,
      ),
      adapterTimeout: const Duration(milliseconds: 20),
      startScan: () async => fail('must not scan an unready adapter'),
    );

    await expectLater(
      session.start(),
      throwsA(
        isA<ScanStartException>().having(
          (e) => e.message,
          'message',
          contains('still starting up'),
        ),
      ),
    );
  });
}

// Manual BLE smoke test: requires Bluetooth to be on and authorized on the
// host. Guards the first-scan path on macOS, where CoreBluetooth needs a moment
// to reach `on` before flutter_blue_plus accepts startScan.
//
//   flutter test integration_test/ble_scan_smoke_test.dart -d macos
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshchameleon/services/scan_session.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('first scan starts after the adapter settles', (tester) async {
    final session = const BleScanSession();
    await session.start();
    addTearDown(() => session.stop());
    expect(FlutterBluePlus.isScanningNow, isTrue);
  });
}

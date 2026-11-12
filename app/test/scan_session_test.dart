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
}

import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/services/device_capabilities.dart';

void main() {
  final originalProbe = DeviceCapabilities.platformProbe;

  tearDown(() => DeviceCapabilities.platformProbe = originalProbe);

  test('current() reflects the host platform probe', () {
    DeviceCapabilities.platformProbe = () => false;
    expect(DeviceCapabilities.current().supportsBle, isFalse);

    DeviceCapabilities.platformProbe = () => true;
    expect(DeviceCapabilities.current().supportsBle, isTrue);
  });

  test('the default probe enables BLE everywhere the plugin is implemented',
      () {
    DeviceCapabilities.platformProbe = originalProbe;
    final expected = Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isLinux;
    expect(DeviceCapabilities.current().supportsBle, equals(expected));
  });

  test('explicit capabilities override the host probe', () {
    DeviceCapabilities.platformProbe = () => true;
    expect(const DeviceCapabilities(supportsBle: false).supportsBle, isFalse);
  });
}

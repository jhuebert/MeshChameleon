import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/services/device_link_phase.dart';
import 'package:meshchameleon/services/foreground_controller.dart';
import 'package:meshchameleon/services/foreground_service.dart';
import 'package:meshchameleon/services/proxy_status.dart';

class FakeForegroundService extends ForegroundService {
  bool supported = true;
  bool fail = false;
  int opened = 0;

  @override
  bool get isSupported => supported;

  @override
  Future<bool> isIgnoringBatteryOptimizations() async {
    if (fail) throw StateError('unavailable');
    return true;
  }

  @override
  Future<bool> openBatteryOptimizationSettings() async {
    opened++;
    if (fail) throw StateError('unavailable');
    return true;
  }
}

void main() {
  test('battery status and settings are platform-gated and handle failure',
      () async {
    final service = FakeForegroundService();
    final logs = <String>[];
    final controller = ForegroundController(
      service: service,
      identityCount: () => 0,
      activeName: () => null,
      devicePhase: () => DeviceLinkPhase.idle,
      deviceConnected: () => false,
      proxyStatus: () => ProxyStatus.stopped,
      port: () => 5000,
      log: logs.add,
    );
    expect(await controller.batteryStatus(), isTrue);
    await controller.openBatterySettings();
    expect(service.opened, 1);
    service.fail = true;
    expect(await controller.batteryStatus(), isNull);
    await controller.openBatterySettings();
    expect(logs, hasLength(2));
    service.supported = false;
    expect(await controller.batteryStatus(), isNull);
    await controller.openBatterySettings();
    expect(service.opened, 2);
  });
}

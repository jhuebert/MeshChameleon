import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/services/ble_device_link.dart';

ScanResult _result({
  required String advName,
  String remoteId = 'E0:72:A1:D9:7C:95',
}) {
  return ScanResult(
    device: BluetoothDevice.fromId(remoteId),
    advertisementData: AdvertisementData(
      advName: advName,
      txPowerLevel: null,
      appearance: null,
      connectable: true,
      manufacturerData: const {},
      serviceData: const {},
      serviceUuids: const [],
    ),
    rssi: -50,
    timeStamp: DateTime.now(),
  );
}

void main() {
  test('advertised name wins over the stale platform name', () {
    expect(
      bleCompanionDisplayName(_result(advName: 'MeshCore-nc1v')),
      'MeshCore-nc1v',
    );
  });

  test('falls back to the remote id when no name is advertised', () {
    expect(
      bleCompanionDisplayName(_result(advName: '')),
      'E0:72:A1:D9:7C:95',
    );
  });
}

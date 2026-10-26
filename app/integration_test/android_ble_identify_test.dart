// Android BLE identification test: map advertised NUS names to the companion's
// SELF_INFO node name and verify the full proxy handshake.
//
//   flutter test integration_test/android_ble_identify_test.dart -d <device> \
//     --dart-define=BLE_NAME=<advertised name substring>
import 'dart:async';
import 'dart:io';

import 'package:companion_server/companion_server.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'package:meshchameleon/services/ble_device_link.dart';

const _bleName = String.fromEnvironment('BLE_NAME');

Future<ScanResult> _scanFor(String needle) async {
  final found = <String, ScanResult>{};
  final sub = FlutterBluePlus.scanResults.listen((results) {
    for (final r in results) {
      if (r.device.platformName.isNotEmpty) found[r.device.platformName] = r;
    }
  });
  await FlutterBluePlus.startScan(
    withServices: [MeshCoreUuids.serviceGuid],
    timeout: const Duration(seconds: 20),
    androidScanMode: AndroidScanMode.lowLatency,
  );
  await FlutterBluePlus.isScanning
      .where((s) => !s)
      .first
      .timeout(const Duration(seconds: 30), onTimeout: () => false);
  await sub.cancel();
  debugPrint('BLE scan found: ${found.keys.toList()}');
  final matches = found.entries.where(
    (e) => e.key.toLowerCase().contains(needle.toLowerCase()),
  );
  if (matches.isEmpty) {
    throw StateError('No BLE match for "$needle" in ${found.keys.toList()}');
  }
  return matches.first.value;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('identify BLE companion and proxy handshake', (tester) async {
    if (_bleName.isEmpty) {
      fail('Set BLE_NAME to the advertised companion name substring.');
    }
    final scan = await _scanFor(_bleName);
    final device = scan.device;
    debugPrint('ADVERT ${device.platformName} id=${device.remoteId} '
        'rssi=${scan.rssi}');
    final link = BleDeviceLink(device: device, onLog: debugPrint);
    await link.connect();
    MeshNode? node;
    CompanionServer? server;
    try {
      final info = await link.deviceInfo();
      final self = await link.selfInfo();
      final params = await link.radioParams();
      debugPrint('DEVICE_INFO fw=${info.firmwareVerCode} '
          'maxContacts=${info.maxContacts} maxChannels=${info.maxChannels} '
          'repeat=${info.clientRepeat} path=${info.pathHashMode} '
          'board="${info.manufacturer}" version="${info.version}"');
      debugPrint('SELF_INFO name="${self.nodeName}" '
          'pub=${bytesToHex(self.publicKey.sublist(0, 6))} '
          'freq=${params.frequencyHz} bw=${params.bandwidthHz} '
          'sf=${params.spreadingFactor} cr=${params.codingRate} '
          'tx=${self.txPowerDbm}/${self.maxTxPower}');
      final battery = await link.battery();
      debugPrint('BATTERY mV=${battery?.millivolts} '
          'storage=${battery?.storageUsedKb}/${battery?.storageTotalKb} KiB');
      expect(battery, isNotNull);
      expect(self.nodeName, isNotEmpty);

      final identity = await LocalIdentity.generate();
      node = MeshNode(
        identity: identity,
        link: link,
        physical: PhysicalCapabilities.fromDeviceInfo(info),
        store: InMemoryNodeStore(),
        prefs: NodePrefs(nodeName: 'Android BLE HIL'),
      );
      await node.load();
      node.syncRadioParams(params);
      node.start();
      server = CompanionServer(
        bridge: node,
        config: const CompanionServerConfig(port: 0),
        onLog: debugPrint,
      );
      await server.start();
      final socket = await Socket.connect('127.0.0.1', server.port!);
      final client = _FramedClient(socket);
      client.send([cmdDeviceQuery, appProtocolVersion]);
      expect((await client.next())[0], respCodeDeviceInfo);
      client.send([cmdAppStart, appProtocolVersion]);
      final selfInfo = await client.next();
      expect(selfInfo[0], respCodeSelfInfo);
      expect(selfInfo.sublist(4, 36), identity.publicKey);
      debugPrint(
          'PROXY_HANDSHAKE_OK key=${bytesToHex(identity.publicKey.sublist(0, 6))}');
      await client.close();
      debugPrint('ANDROID_BLE_IDENTIFY_OK name="${self.nodeName}"');
    } finally {
      await server?.stop();
      node?.stop();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await link.disconnect();
    }
  });
}

class _FramedClient {
  _FramedClient(this.socket) {
    _sub = socket.listen((data) {
      for (final frame in _codec.ingest(data)) {
        _onFrame(frame);
      }
    });
  }
  final Socket socket;
  final SerialFrameCodec _codec = SerialFrameCodec.bidirectional();
  late final StreamSubscription<List<int>> _sub;
  final List<Uint8List> _buffer = [];
  final List<Completer<Uint8List>> _waiters = [];

  void send(List<int> payload) {
    socket.add(_codec.encodeFrame(payload, prefix: frameInboundPrefix));
  }

  Future<Uint8List> next() {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    final c = Completer<Uint8List>();
    _waiters.add(c);
    return c.future.timeout(const Duration(seconds: 10));
  }

  Future<void> close() async {
    await _sub.cancel();
    await socket.close();
  }

  void _onFrame(Uint8List frame) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(frame);
    } else {
      _buffer.add(frame);
    }
  }
}

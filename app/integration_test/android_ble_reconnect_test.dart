// Android BLE lifecycle test: physical reboot while a client is attached,
// automatic reconnect, and virtual identity continuity.
//
// This reboots the radio.
//   flutter test integration_test/android_ble_reconnect_test.dart -d <device> \
//     --dart-define=BLE_NAME=<advertised name substring>
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_link/device_link.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/services/ble_device_link.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/network_connection_store.dart';
import 'package:meshchameleon/services/session_store.dart';
import 'package:path_provider/path_provider.dart';

const _bleName = String.fromEnvironment('BLE_NAME');
const _proxyPort = int.fromEnvironment('PROXY_PORT', defaultValue: 5224);

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

  testWidgets('BLE reboot reconnects and preserves the virtual identity',
      (tester) async {
    if (_bleName.isEmpty) {
      fail('Set BLE_NAME to the advertised companion name substring.');
    }
    final tmp = await getTemporaryDirectory();
    final dir = Directory(
        '${tmp.path}/mesh_ble_reconnect_${DateTime.now().microsecondsSinceEpoch}');
    await dir.create(recursive: true);
    final store = IdentityStore();
    final app = AppState(
      repository: IdentityRepository(
        supportDirectory: dir,
        secureStore: store,
      ),
      sessionStore: SessionStore(file: File('${dir.path}/session.json')),
      networkConnectionStore:
          NetworkConnectionStore(file: File('${dir.path}/history.json')),
      capabilities: DeviceCapabilities.current(),
      reconnectDelay: const Duration(seconds: 2),
    );
    final ids = <String>[];
    addTearDown(() async {
      await app.disconnectDevice();
      await app.manager?.dispose();
      for (final id in ids) {
        try {
          await store.deleteById(id);
        } catch (_) {}
      }
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    await tester.runAsync(() async {
      await app.loadIdentities();
      ids.addAll(app.identities.map((i) => i.id));
      expect(await app.setProxyPort(_proxyPort), isTrue);
    });
    final scan = await _scanFor(_bleName);
    expect(await app.connectBle(scan.device), isTrue);
    await tester.runAsync(() => app.startProxy(serverPort: _proxyPort));
    expect(app.proxyStatus, ProxyStatus.running);
    final originalKey = bytesToHex(app.identity!.publicKey);
    final link = app.link!;
    final states = <LinkState>[];
    final stateSub = link.state.listen(states.add);
    addTearDown(stateSub.cancel);

    final socket = await Socket.connect('127.0.0.1', _proxyPort);
    final client = _FramedClient(socket);
    try {
      client.send([cmdDeviceQuery, appProtocolVersion]);
      await client.next();
      client.send([cmdAppStart, appProtocolVersion]);
      final self = await client.next();
      expect(self.sublist(4, 36), app.identity!.publicKey);
      debugPrint('BEFORE_REBOOT key=$originalKey port=$_proxyPort');

      client.send([cmdRunCliCommand, ...utf8.encode('reboot')]);
      final reply = await client.next();
      expect(reply[0], respCodeCliReply);
      debugPrint('REBOOT_REPLY "${utf8.decode(reply.sublist(1))}"');

      var sawDisconnect = false;
      var reconnected = false;
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(deadline)) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 300)));
        if (states.contains(LinkState.disconnected)) sawDisconnect = true;
        if (sawDisconnect && link.currentState == LinkState.connected) {
          reconnected = true;
          break;
        }
      }
      debugPrint('LINK_STATES ${states.map((s) => s.name).toList()} '
          'current=${link.currentState.name}');
      expect(sawDisconnect, isTrue, reason: 'reboot did not drop the BLE link');
      expect(reconnected, isTrue, reason: 'app did not reconnect over BLE');
      expect(app.proxyStatus, ProxyStatus.running);
      expect(bytesToHex(app.identity!.publicKey), originalKey);
      final actual = await tester.runAsync(() => app.link!.deviceInfo());
      debugPrint('AFTER_RECONNECT fw=${actual!.firmwareVerCode} '
          'key=$originalKey connected=${app.deviceConnected}');
      final second =
          _FramedClient(await Socket.connect('127.0.0.1', _proxyPort));
      try {
        second.send([cmdDeviceQuery, appProtocolVersion]);
        await second.next();
        second.send([cmdAppStart, appProtocolVersion]);
        final self2 = await second.next();
        expect(self2.sublist(4, 36), hexToBytes(originalKey));
      } finally {
        await second.close();
      }
      debugPrint('BLE_RECONNECT_OK');
    } finally {
      await client.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

class _FramedClient {
  _FramedClient(this.socket) {
    _sub = socket.listen((data) {
      for (final frame in _codec.ingest(data)) {
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).complete(frame);
        } else {
          _buffer.add(frame);
        }
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
    return c.future.timeout(const Duration(seconds: 20));
  }

  Future<void> close() async {
    await _sub.cancel();
    await socket.close();
  }
}

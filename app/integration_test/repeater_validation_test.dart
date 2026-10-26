// Hardware validation (not part of the default gate).
//
// Drives the app-facing companion protocol against the proxy to log in to a
// repeater and fetch its status, using a real BLE companion tuned to the
// repeater's channel.
//
//   flutter test integration_test/repeater_validation_test.dart -d <id> \
//     --dart-define=BLE_NAME=<name> \
//     --dart-define=REPEATER_PUBKEY_HEX=<hex> \
//     --dart-define=REPEATER_PASSWORD=<password> \
//     [--dart-define=REPEATER_FREQ_HZ=926000000] \
//     [--dart-define=REPEATER_BW_HZ=125000] \
//     [--dart-define=REPEATER_SF=8] [--dart-define=REPEATER_CR=5]
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
const _pubkeyHex = String.fromEnvironment('REPEATER_PUBKEY_HEX');
const _password = String.fromEnvironment('REPEATER_PASSWORD');
const _repeaterFrequencyHz =
    int.fromEnvironment('REPEATER_FREQ_HZ', defaultValue: 926000000);
const _repeaterBandwidthHz =
    int.fromEnvironment('REPEATER_BW_HZ', defaultValue: 125000);
const _repeaterSpreadingFactor =
    int.fromEnvironment('REPEATER_SF', defaultValue: 8);
const _repeaterCodingRate =
    int.fromEnvironment('REPEATER_CR', defaultValue: 5);

Future<BluetoothDevice> _scanFor(String needle) async {
  final found = <String, ScanResult>{};
  final sub = FlutterBluePlus.scanResults.listen((results) {
    for (final r in results) {
      final name = r.device.platformName;
      if (name.isNotEmpty) found[name] = r;
    }
  });
  await FlutterBluePlus.startScan(
    withServices: [MeshCoreUuids.serviceGuid],
    timeout: const Duration(seconds: 20),
    androidScanMode: AndroidScanMode.lowLatency,
  );
  await FlutterBluePlus.isScanning
      .where((s) => s == false)
      .first
      .timeout(const Duration(seconds: 30), onTimeout: () => false);
  await sub.cancel();
  final names = found.keys.toList();
  debugPrint('BLE scan found: $names');
  final match =
      found.entries.where((e) => e.key.toLowerCase().contains(needle.toLowerCase()));
  if (match.isEmpty) {
    if (found.length == 1) return found.values.first.device;
    throw StateError('No match for "$needle"; saw $names');
  }
  return match.first.value.device;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('repeater login + status via the proxy', (tester) async {
    if (_bleName.isEmpty || _pubkeyHex.isEmpty || _password.isEmpty) {
      fail('Set BLE_NAME, REPEATER_PUBKEY_HEX, and REPEATER_PASSWORD.');
    }
    final device = await _scanFor(_bleName);
    final link = BleDeviceLink(device: device, onLog: (m) => debugPrint('[ble] $m'));
    await link.connect();
    addTearDown(link.disconnect);

    final info = await link.deviceInfo();
    final orig = await link.radioParams();
    debugPrint('device fw=${info.firmwareVerCode} orig freq=${orig.frequencyHz} '
        'bw=${orig.bandwidthHz} sf=${orig.spreadingFactor} cr=${orig.codingRate}');

    final identity = await LocalIdentity.generate();
    final node = MeshNode(
      identity: identity,
      link: link,
      physical: PhysicalCapabilities.fromDeviceInfo(info),
      store: InMemoryNodeStore(),
    );
    await node.load();
    node.syncRadioParams(orig);
    node.start();
    addTearDown(node.stop);

    final server = CompanionServer(
      bridge: node,
      config: const CompanionServerConfig(port: 0),
      onLog: (m) => debugPrint('[server] $m'),
    );
    await server.start();
    addTearDown(server.stop);

    final client = _FramedClient(await Socket.connect('127.0.0.1', server.port!));
    addTearDown(client.close);
    client.send([cmdDeviceQuery, appProtocolVersion]);
    await client.next();
    client.send([cmdAppStart, appProtocolVersion]);
    await client.next();

    final pubkey = Uint8List.fromList(_parseHex(_pubkeyHex));
    const target = RadioParams(
      frequencyHz: _repeaterFrequencyHz,
      bandwidthHz: _repeaterBandwidthHz,
      spreadingFactor: _repeaterSpreadingFactor,
      codingRate: _repeaterCodingRate,
    );
    try {
      await link.setRadioParams(target);
      node.syncRadioParams(target);
      final applied = await link.radioParams();
      debugPrint('device applied: freq=${applied.frequencyHz} '
          'bw=${applied.bandwidthHz} sf=${applied.spreadingFactor} '
          'cr=${applied.codingRate}');
      await Future<void>.delayed(const Duration(seconds: 2));

      node.addUpdateContact(Contact(
        publicKey: pubkey,
        name: 'Repeater',
        advType: advTypeRepeater,
      ));

      // Login (ANON_REQ with the repeater admin password).
      client.send([cmdSendLogin, ...pubkey, ..._password.codeUnits, 0]);
      final loginReply = await client.next();
      debugPrint('login reply code=${loginReply.isEmpty ? "none" : loginReply[0]}');
      final loggedIn =
          await client.awaitCode(pushCodeLoginSuccess, const Duration(seconds: 15));
      debugPrint('LOGIN ${loggedIn ? "OK" : "no LOGIN_SUCCESS"}');

      // Status request.
      client.send([cmdSendStatusReq, ...pubkey]);
      final statusSent = await client.next();
      debugPrint('status reply code=${statusSent.isEmpty ? "none" : statusSent[0]}');
      final gotStatus =
          await client.awaitCode(pushCodeStatusResponse, const Duration(seconds: 15));
      debugPrint('STATUS ${gotStatus ? "OK" : "no STATUS_RESPONSE"}');

      // Has-connection check on the keep-alive session.
      client.send([cmdHasConnection, ...pubkey]);
      final has = await client.next();
      debugPrint('HAS_CONNECTION reply=${has.isEmpty ? "none" : has.sublist(0, has.length < 3 ? has.length : 3)}');

      // Binary request (CMD_SEND_BINARY_REQ 50) with REQ_TYPE_GET_STATUS.
      client.send([cmdSendBinaryReq, ...pubkey, reqTypeGetStatus]);
      debugPrint('BINARY STATUS send reply=${(await client.next())[0]}');
      final binOk = await client.awaitCode(
          pushCodeBinaryResponse, const Duration(seconds: 25));
      debugPrint('BINARY STATUS ${binOk ? "OK" : "no response within 25s"}');

      // Telemetry request (CMD_SEND_TELEMETRY_REQ 39) to the repeater.
      client.send([cmdSendTelemetryReq, 0, 0, 0, ...pubkey]);
      debugPrint('TELEMETRY send reply=${(await client.next())[0]}');
      final telemOk = await client.awaitCode(
          pushCodeTelemetryResponse, const Duration(seconds: 25));
      debugPrint('TELEMETRY ${telemOk ? "OK" : "no response within 25s"}');
    } finally {
      debugPrint('restoring device radio');
      await link.setRadioParams(orig);
      node.syncRadioParams(orig);
    }
  });
}

List<int> _parseHex(String hex) {
  final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  return [
    for (var i = 0; i + 1 < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ];
}

class _FramedClient {
  _FramedClient(this._socket) {
    _socket.listen((data) {
      for (final f in _codec.ingest(data)) {
        _controller.add(f);
      }
    });
  }
  final Socket _socket;
  final SerialFrameCodec _codec = SerialFrameCodec.bidirectional();
  final _controller = StreamController<Uint8List>.broadcast();
  late final _Queue<Uint8List> _frames = _Queue(_controller.stream);

  void send(List<int> payload) =>
      _socket.add(_codec.encodeFrame(payload, prefix: frameInboundPrefix));

  Future<Uint8List> next() => _frames
      .next()
      .timeout(const Duration(seconds: 15), onTimeout: () => Uint8List(0));

  Future<bool> awaitCode(int code, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final frame = await _frames
          .next()
          .timeout(deadline.difference(DateTime.now()), onTimeout: () => Uint8List(0));
      if (frame.isEmpty) return false;
      if (frame[0] == code) return true;
    }
    return false;
  }

  Future<void> close() async {
    await _controller.close();
    await _socket.close();
  }
}

class _Queue<T> {
  _Queue(Stream<T> stream) {
    stream.listen(_add);
  }
  final List<T> _buffer = [];
  final List<Completer<T>> _waiters = [];
  Future<T> next() {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    final c = Completer<T>();
    _waiters.add(c);
    return c.future;
  }

  void _add(T value) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(value);
    } else {
      _buffer.add(value);
    }
  }
}

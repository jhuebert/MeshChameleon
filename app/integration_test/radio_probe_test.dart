// Temporary hardware probe (not part of the default gate).
//
// Connects BLE to a companion, then tries candidate radio configs while sending
// a flooded path-discovery request to a known repeater public key. The repeater
// answers path discovery (stock companions do not), so the config that gets a
// PATH_DISCOVERY_RESPONSE is the repeater's actual on-air config.
//
//   flutter test integration_test/radio_probe_test.dart -d <device-id> \
//     --dart-define=REPEATER_PUBKEY_HEX=<hex>
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

const _bleName = String.fromEnvironment('BLE_NAME', defaultValue: 'nc1v');
const _pubkeyHex = String.fromEnvironment('REPEATER_PUBKEY_HEX',
    defaultValue:
        'DEC0DEDEDC77F3ED96ED5C8756D2A572B86D9D71D007D2114C384DF8E0B421B3');

class _Cand {
  const _Cand(this.label, this.radio);
  final String label;
  final RadioParams radio;
}

final _cands = <_Cand>[
  const _Cand('repeater 926.0/125/8/5',
      RadioParams(frequencyHz: 926000000, bandwidthHz: 125000, spreadingFactor: 8, codingRate: 5)),
];

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

  testWidgets('find the repeater radio config', (tester) async {
    final device = await _scanFor(_bleName);
    final link = BleDeviceLink(device: device, onLog: (m) => debugPrint('[ble] $m'));
    await link.connect();
    addTearDown(link.disconnect);

    final info = await link.deviceInfo();
    final orig = await link.radioParams();
    debugPrint('nc1v fw=${info.firmwareVerCode} orig freq=${orig.frequencyHz} '
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
    debugPrint('probing for repeater ${bytesToHex(pubkey.sublist(0, 6))}');

    String? found;
    try {
      for (final c in _cands) {
        await link.setRadioParams(c.radio);
        node.syncRadioParams(c.radio);
        final applied = await link.radioParams();
        debugPrint('nc1v applied: freq=${applied.frequencyHz} '
            'bw=${applied.bandwidthHz} sf=${applied.spreadingFactor} '
            'cr=${applied.codingRate}');
        await Future<void>.delayed(const Duration(seconds: 2));
        node.addUpdateContact(Contact(
          publicKey: pubkey,
          name: 't1000-e Repeater',
          advType: advTypeRepeater,
        ));
        // Flood an advert so the repeater records us as a neighbour (proves the
        // companion->repeater TX path independently of the request/reply path).
        await node.advertise();
        await Future<void>.delayed(const Duration(seconds: 2));
        client.send([cmdSendPathDiscoveryReq, 0, ...pubkey]);
        final resp = await client.next();
        debugPrint('path-discovery send reply code=${resp.isEmpty ? "none" : resp[0]}');
        final ok =
            await client.awaitCode(pushCodePathDiscoveryResponse, const Duration(seconds: 12));
        debugPrint('CAND ${c.label} -> ${ok ? "RESPONSE!" : "no response"}');
        if (ok) {
          found = c.label;
          break;
        }
      }
    } finally {
      debugPrint('restoring nc1v radio');
      await link.setRadioParams(orig);
      node.syncRadioParams(orig);
    }
    debugPrint(found != null ? 'FOUND REPEATER CONFIG: $found' : 'no candidate matched');
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

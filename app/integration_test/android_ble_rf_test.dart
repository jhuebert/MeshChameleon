// Android BLE RF test: virtual DM to a peer over a real BLE link, plus peer
// contact cleanup. One RF DM per run.
//
//   flutter test integration_test/android_ble_rf_test.dart -d <device> \
//     --dart-define=BLE_NAME=<name> --dart-define=PEER_HOST=<host> \
//     --dart-define=PEER_PUBKEY_HEX=<64-byte hex> [--dart-define=PEER_PORT=9505]
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
const _peerHost = String.fromEnvironment('PEER_HOST');
const _peerPort = int.fromEnvironment('PEER_PORT', defaultValue: 9505);
const _peerKeyHex = String.fromEnvironment('PEER_PUBKEY_HEX');

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

  testWidgets('virtual DM over BLE to a peer', (tester) async {
    if (_bleName.isEmpty || _peerHost.isEmpty || _peerKeyHex.isEmpty) {
      fail('Set BLE_NAME, PEER_HOST, and PEER_PUBKEY_HEX.');
    }
    final scan = await _scanFor(_bleName);
    debugPrint('ADVERT ${scan.device.platformName} rssi=${scan.rssi}');
    final link = BleDeviceLink(device: scan.device, onLog: debugPrint);
    await link.connect();
    MeshNode? node;
    CompanionServer? server;
    var registered = false;
    Uint8List? virtualKey;
    try {
      final info = await link.deviceInfo();
      final self = await link.selfInfo();
      final params = await link.radioParams();
      debugPrint(
          'BLE_DEVICE fw=${info.firmwareVerCode} name="${self.nodeName}" '
          'freq=${params.frequencyHz} sf=${params.spreadingFactor}');
      final identity = await LocalIdentity.generate();
      virtualKey = identity.publicKey;
      node = MeshNode(
        identity: identity,
        link: link,
        physical: PhysicalCapabilities.fromDeviceInfo(info),
        store: InMemoryNodeStore(),
        prefs: NodePrefs(nodeName: 'Android BLE RF'),
      );
      await node.load();
      node.syncRadioParams(params);
      node.start();
      final peerKey = Uint8List.fromList(hexToBytes(_peerKeyHex));
      await node.addUpdateContact(Contact(
        publicKey: peerKey,
        name: 'TestCompanion',
        outPathLen: 0,
        outPath: Uint8List(0),
      ));
      await _registerContact(_peerHost, _peerPort, identity.publicKey);
      registered = true;

      server = CompanionServer(
        bridge: node,
        config: const CompanionServerConfig(port: 0),
        onLog: debugPrint,
      );
      await server.start();
      final client =
          _FramedClient(await Socket.connect('127.0.0.1', server.port!));
      try {
        client.send([cmdDeviceQuery, appProtocolVersion]);
        await client.next();
        client.send([cmdAppStart, appProtocolVersion]);
        await client.next();
        final text =
            'ANDROID-BLE-${self.nodeName}-${DateTime.now().millisecondsSinceEpoch}';
        client.send(
          (BufferWriter()
                ..writeByte(cmdSendTxtMsg)
                ..writeByte(txtTypePlain)
                ..writeByte(0)
                ..writeUInt32Le(0)
                ..writeBytes(peerKey.sublist(0, 6))
                ..writeString(text)
                ..writeByte(0))
              .toBytes(),
        );
        final sent = await client.next();
        debugPrint('DM sent code=${sent[0]} text="$text"');
        expect(sent[0], respCodeSent);
        final confirmed = await client.awaitCode(
          pushCodeSendConfirmed,
          const Duration(seconds: 20),
        );
        expect(confirmed, isTrue);
        debugPrint('BLE_RF_DM_OK companion="${self.nodeName}" text="$text"');
      } finally {
        await client.close();
      }
    } finally {
      await server?.stop();
      node?.stop();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await link.disconnect();
      if (registered && virtualKey != null) {
        try {
          await _removeContact(_peerHost, _peerPort, virtualKey);
          debugPrint('PEER_CONTACT_REMOVED');
        } catch (e) {
          debugPrint('PEER_CONTACT_REMOVE_FAILED $e');
        }
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<void> _registerContact(String host, int port, Uint8List pubkey) async {
  final socket =
      await Socket.connect(host, port, timeout: const Duration(seconds: 10));
  socket.setOption(SocketOption.tcpNoDelay, true);
  final client = _FramedClient(socket);
  try {
    client.send([cmdDeviceQuery, appProtocolVersion]);
    await client.next();
    client.send([cmdAppStart, appProtocolVersion]);
    await client.next();
    client.send(
      (BufferWriter()
            ..writeByte(cmdAddUpdateContact)
            ..writeBytes(pubkey)
            ..writeByte(0)
            ..writeByte(0)
            ..writeByte(0xFF)
            ..writeBytesPadded(const <int>[], maxPathSize)
            ..writeCString('Android BLE RF', maxNameSize))
          .toBytes(),
    );
    final reply = await client.next();
    debugPrint('PEER_ADD_CONTACT code=${reply[0]}');
    expect(reply[0], respCodeOk);
  } finally {
    await client.close();
  }
}

Future<void> _removeContact(String host, int port, Uint8List pubkey) async {
  final socket =
      await Socket.connect(host, port, timeout: const Duration(seconds: 10));
  socket.setOption(SocketOption.tcpNoDelay, true);
  final client = _FramedClient(socket);
  try {
    client.send([cmdDeviceQuery, appProtocolVersion]);
    await client.next();
    client.send([cmdAppStart, appProtocolVersion]);
    await client.next();
    client.send([cmdRemoveContact, ...pubkey]);
    final reply = await client.next();
    debugPrint('PEER_REMOVE_CONTACT code=${reply[0]}');
  } finally {
    await client.close();
  }
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

  Future<Uint8List> next({bool includePushes = false}) async {
    while (true) {
      final frame =
          _buffer.isNotEmpty ? _buffer.removeAt(0) : await _nextFrame();
      if (!includePushes && frame.isNotEmpty && frame[0] >= 0x80) continue;
      return frame;
    }
  }

  Future<Uint8List> _nextFrame() {
    final c = Completer<Uint8List>();
    _waiters.add(c);
    return c.future.timeout(const Duration(seconds: 20));
  }

  Future<bool> awaitCode(int code, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final frame = await next(includePushes: true);
      if (frame.isNotEmpty && frame[0] == code) return true;
    }
    return false;
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

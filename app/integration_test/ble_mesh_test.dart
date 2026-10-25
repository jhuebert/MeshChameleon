// Hardware-in-the-loop test for the BLE device link and the proxy stack.
//
// This test is deliberately NOT part of the default `flutter test` gate: it
// needs a real companion device, a real radio, and (for the optional TX phase)
// consent to transmit on the air. Run it explicitly:
//
//   flutter test integration_test/ble_mesh_test.dart -d <device-id>
//
// Configuration via --dart-define:
//   BLE_NAME       substring of the advertised device name to connect to
//                  (default: "nc1v")
//   DO_TX          "true" to advertise and send a channel text on air
//                  (default: off — scan/connect/handshake only)
//   CHANNEL_NAME   channel name when DO_TX (default: the public channel)
//   CHANNEL_PSK_HEX  16-byte PSK hex when DO_TX (default: public channel PSK)
//
// With DO_TX it reports how many transmitted frames were heard back over the
// raw RX path (a relayed echo), which is a strong signal that the frame really
// left the radio and was routed by the mesh.
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
const _doTx = bool.fromEnvironment('DO_TX');
// Adverts are heard by every node on the mesh; keep them opt-in.
const _doAdvert = bool.fromEnvironment('DO_ADVERT');
const _channelName = String.fromEnvironment('CHANNEL_NAME');
const _channelPskHex = String.fromEnvironment('CHANNEL_PSK_HEX');
const _peerPubkeyHex = String.fromEnvironment('PEER_PUBKEY_HEX');
// Optional: register the proxy identity as a contact on a network companion so
// a DM can be decrypted/ACKed without broadcasting an advert.
const _peerHost = String.fromEnvironment('PEER_HOST');
const _peerPort = int.fromEnvironment('PEER_PORT');

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
  await FlutterBluePlus.isScanning.where((s) => s == false).first
      .timeout(const Duration(seconds: 30), onTimeout: () => false);
  await sub.cancel();

  final names = found.keys.toList();
  debugPrint('BLE scan found: $names');
  final match = found.entries.where(
    (e) => e.key.toLowerCase().contains(needle.toLowerCase()),
  );
  if (match.isEmpty) {
    if (found.length == 1) {
      final only = found.values.first;
      debugPrint('No name matched "$needle"; using the only NUS device '
          '"${only.device.platformName}".');
      return only.device;
    }
    throw StateError(
      'No BLE device matching "$needle" found. Saw: ${names.join(", ")}',
    );
  }
  return match.first.value.device;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('BLE device link: scan, connect, handshake, proxy stack',
      (tester) async {
    final device = await _scanFor(_bleName);
    debugPrint('Connecting to BLE "${device.platformName}" '
        '(${device.remoteId}) ...');

    final link = BleDeviceLink(
      device: device,
      onLog: (m) => debugPrint('[ble] $m'),
    );
    await link.connect();
    addTearDown(link.disconnect);

    final info = await link.deviceInfo();
    final params = await link.radioParams();
    debugPrint('DEVICE_INFO fw=${info.firmwareVerCode} '
        'maxContacts=${info.maxContacts} maxChannels=${info.maxChannels} '
        'clientRepeat=${info.clientRepeat} pathHashMode=${info.pathHashMode}');
    debugPrint('  manufacturer="${info.manufacturer}" '
        'version="${info.version}"');
    debugPrint('RADIO freq=${params.frequencyHz}Hz bw=${params.bandwidthHz}Hz '
        'sf=${params.spreadingFactor} cr=${params.codingRate}');
    expect(info.firmwareVerCode, greaterThan(0));

    // Full proxy stack over the real BLE device link, ephemeral identity.
    final identity = await LocalIdentity.generate();
    debugPrint('Proxy identity pubkey=${bytesToHex(identity.publicKey)}');
    final node = MeshNode(
      identity: identity,
      link: link,
      physical: PhysicalCapabilities.fromDeviceInfo(info),
      store: InMemoryNodeStore(),
      prefs: NodePrefs(nodeName: 'BLE Test Proxy'),
    );
    await node.load();
    node.syncRadioParams(params);
    node.start();
    addTearDown(node.stop);

    final server = CompanionServer(
      bridge: node,
      config: const CompanionServerConfig(port: 0),
      onLog: (m) => debugPrint('[server] $m'),
    );
    await server.start();
    addTearDown(server.stop);

    final client = _FramedClient(
      await Socket.connect('127.0.0.1', server.port!)
        ..setOption(SocketOption.tcpNoDelay, true),
    );
    addTearDown(client.close);

    // App-side handshake, exactly as meshcore-open performs it.
    client.send([cmdDeviceQuery, appProtocolVersion]);
    expect((await client.next())[0], respCodeDeviceInfo);

    client.send([cmdAppStart, appProtocolVersion]);
    final selfInfo = await client.next();
    expect(selfInfo[0], respCodeSelfInfo);
    expect(selfInfo.sublist(4, 36), identity.publicKey);
    debugPrint('Proxy SELF_INFO reports the phone identity: OK');

    // Optional on-air phase.
    if (!_doTx) {
      debugPrint('DO_TX not set: skipping advert/channel transmit.');
      return;
    }

    if (_channelName.isNotEmpty && _channelPskHex.isNotEmpty) {
      node.channels[0] = Channel(
        name: _channelName,
        secret: Uint8List.fromList(_parseHex(_channelPskHex)),
      );
      debugPrint('Using channel "$_channelName"');
    }
    final channel = node.channels[0]!;

    Uint8List? peer;
    if (_peerPubkeyHex.isNotEmpty) {
      peer = Uint8List.fromList(_parseHex(_peerPubkeyHex));
      node.addUpdateContact(Contact(publicKey: peer, name: 'TestCompanion'));
      debugPrint('Added peer contact ${bytesToHex(peer.sublist(0, 6))}');
    }

    final heard = <String, int>{};
    // The node owns the raw-RX listener (set in node.start()) and needs inbound
    // frames to process DM ACKs. Only override it when ECHO_RX is explicitly set
    // (diagnostic echo counting, which disables node RX processing).
    if (const bool.fromEnvironment('ECHO_RX')) {
      debugPrint('ECHO_RX set: node RX processing is bypassed');
      link.setRawRxListener((snr, rssi, raw) {
        final pkt = Packet.readFrom(raw);
        if (pkt == null) return;
        final key = bytesToHex(pkt.payload.take(8).toList());
        heard[key] = (heard[key] ?? 0) + 1;
      });
    }

    // Advertise the proxy identity (opt-in; adverts are mesh-wide).
    if (_doAdvert) {
      final advertised = await node.advertise();
      debugPrint('advertise() -> $advertised');
      expect(advertised, isTrue);
      client.send([cmdSendSelfAdvert]);
      expect((await client.next())[0], respCodeOk);
      debugPrint('ADVERT transmitted');
    }

    // Channel text on the (possibly custom) channel 0.
    final message = 'proxy ble test ${DateTime.now().millisecondsSinceEpoch}';
    client.send(
      (BufferWriter()
            ..writeByte(cmdSendChannelTxtMsg)
            ..writeByte(txtTypePlain)
            ..writeByte(0)
            ..writeUInt32Le(0)
            ..writeString(message)
            ..writeByte(0))
          .toBytes(),
    );
    expect((await client.next())[0], respCodeOk);
    debugPrint('CHANNEL sent on "${channel.name}": "$message"');

    // Direct message to the peer identity; expect an ACK (SEND_CONFIRMED).
    if (peer != null) {
      if (_peerHost.isNotEmpty && _peerPort != 0) {
        await _registerContact(_peerHost, _peerPort, identity.publicKey);
      }
      final dm = 'proxy dm test ${DateTime.now().millisecondsSinceEpoch}';
      client.send(
        (BufferWriter()
              ..writeByte(cmdSendTxtMsg)
              ..writeByte(txtTypePlain)
              ..writeByte(0)
              ..writeUInt32Le(0)
              ..writeBytes(peer.sublist(0, 6))
              ..writeString(dm)
              ..writeByte(0))
            .toBytes(),
      );
      final sent = await client.next();
      debugPrint('DM SENT reply code=${sent[0]}');
      debugPrint('DM sent: "$dm"');
      final confirmed = await client.awaitCode(
        pushCodeSendConfirmed,
        const Duration(seconds: 15),
      );
      debugPrint(confirmed
          ? 'DM CONFIRMED: peer ACK received'
          : 'DM NOT confirmed within 15s');
    }

    await Future<void>.delayed(const Duration(seconds: 8));
    debugPrint('Raw RX echoes observed: $heard');
    debugPrint('VALIDATION DONE (proxy pubkey='
        '${bytesToHex(identity.publicKey)})');
  });
}

/// Adds [pubkey] to a network companion's contact table (so it can decrypt a
/// DM from us without us broadcasting an advert).
Future<void> _registerContact(String host, int port, Uint8List pubkey) async {
  final socket = await Socket.connect(host, port,
      timeout: const Duration(seconds: 10));
  socket.setOption(SocketOption.tcpNoDelay, true);
  final client = _FramedClient(socket);
  try {
    client.send([cmdDeviceQuery, appProtocolVersion]);
    await client.next();
    client.send(
      (BufferWriter()
            ..writeByte(cmdAddUpdateContact)
            ..writeBytes(pubkey)
            ..writeByte(0) // advType
            ..writeByte(0) // flags
            ..writeByte(0xFF) // outPathLen: unknown
            ..writeBytesPadded(const <int>[], maxPathSize)
            ..writeCString('ProxyTest', maxNameSize))
          .toBytes(),
    );
    final resp = await client.next();
    debugPrint('Registered contact on peer: reply code='
        '${resp.isEmpty ? "none" : resp[0]}');
  } finally {
    await client.close();
  }
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

  /// Waits for the first frame whose code equals [code], discarding others.
  Future<bool> awaitCode(int code, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final frame = await _frames
          .next()
          .timeout(deadline.difference(DateTime.now()),
              onTimeout: () => Uint8List(0));
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

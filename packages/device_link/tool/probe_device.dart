// M0 feasibility probe for a stock MeshCore companion over TCP.
//
//   dart run tool/probe_device.dart <host> [port] [watch-seconds] [rx|tx]
//
// rx (default): handshake (DEVICE_QUERY, APP_START, battery) then watch
//   PUSH_CODE_LOG_RX_DATA.
// tx: additionally transmit a group text on a throwaway random channel (random
//   16-byte PSK / 16-char name) via CMD_SEND_RAW_PACKET and watch for an echo.
//
// This is read-only apart from the opt-in `tx` mode, which deliberately writes
// nothing to any named/known channel.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: probe_device <host> [port] [watch-seconds] [rx|tx]');
    exit(2);
  }
  final host = args[0];
  final port = args.length > 1 ? int.parse(args[1]) : 9505;
  final watch = Duration(seconds: args.length > 2 ? int.parse(args[2]) : 10);
  final mode = args.length > 3 ? args[3] : 'rx';

  final link = TcpDeviceLink(
    host: host,
    port: port,
    requestTimeout: const Duration(seconds: 12),
    onLog: (m) => stdout.writeln(m),
  );

  stdout.writeln('connecting to $host:$port ...');
  await link.connect();
  stdout.writeln('connected (state=${link.currentState.name})');

  final info = await link.deviceInfo();
  stdout.writeln('DEVICE_INFO fw=${info.firmwareVerCode} '
      'maxContacts=${info.maxContacts} maxChannels=${info.maxChannels} '
      'clientRepeat=${info.clientRepeat} pathHashMode=${info.pathHashMode}');
  stdout.writeln('  manufacturer="${info.manufacturer}" version="${info.version}"');

  final self = await link.selfInfo();
  stdout.writeln('SELF_INFO name="${self.nodeName}" advType=${self.advType}');
  stdout.writeln('  radio freq=${self.radioParams.frequencyHz}Hz '
      'bw=${self.radioParams.bandwidthHz}Hz sf=${self.radioParams.spreadingFactor} '
      'cr=${self.radioParams.codingRate}');
  stdout.writeln('  txPower=${self.txPowerDbm} maxTxPower=${self.maxTxPower} '
      'lat=${self.latitude} lon=${self.longitude}');
  stdout.writeln('  devicePubkey=${bytesToHex(self.publicKey)} (ignored by proxy)');

  final battery = await link.battery();
  stdout.writeln('BATTERY ${battery?.millivolts}mV '
      'storage=${battery?.storageUsedKb}/${battery?.storageTotalKb}KB');

  Packet? sentPacket;
  if (mode == 'tx') {
    sentPacket = await _transmitProbeGroupText(link);
    stdout.writeln(sentPacket == null
        ? 'sentPacket: rejected'
        : 'sentPacket=${bytesToHex(sentPacket.writeTo())}');
  }

  var count = 0;
  var matched = 0;
  link.setRawRxListener((double snr, int rssi, Uint8List raw) {
    count++;
    final pkt = Packet.readFrom(raw);
    final isOurs = sentPacket != null &&
        pkt != null &&
        pkt.payloadType == sentPacket.payloadType &&
        _bytesEqual(pkt.payload, sentPacket.payload);
    if (isOurs) matched++;
    final annotation = isOurs
        ? '  <-- OUR PAYLOAD, hop path hashSize='
            '${pkt.pathHashSize} count=${pkt.pathHashCount}'
            ' path=${bytesToHex(pkt.path)}'
        : '';
    stdout.writeln('RX #$count snr=$snr rssi=$rssi len=${raw.length} '
        'bytes=${bytesToHex(raw)}$annotation');
  });

  stdout.writeln('watching LOG_RX_DATA for ${watch.inSeconds}s ...');
  await Future<void>.delayed(watch);
  stdout.writeln('done: received $count raw frame(s)');
  if (sentPacket != null) {
    stdout.writeln(matched > 0
        ? 'RESULT: our payload was relayed back $matched time(s) with only '
            'repeater-added path bytes (R3: no rewrite observed)'
        : 'RESULT: no relay of our payload observed');
  }

  await link.disconnect();
  stdout.writeln('disconnected');
  // The TCP link can leave the VM alive after a clean disconnect; this is a
  // one-shot diagnostic, so terminate deterministically for scripted callers.
  exit(0);
}

/// Send a single group text on a throwaway random channel and return the
/// packet. Returns null if the device rejected the transmission.
Future<Packet?> _transmitProbeGroupText(TcpDeviceLink link) async {
  final rng = Random.secure();
  final channel = Channel(
    name: _randomChannelName(rng),
    secret: Uint8List.fromList(
        List<int>.generate(16, (_) => rng.nextInt(256))),
  );
  final packet = PacketBuilder.createGroupText(
    channel: channel,
    message: 'M0 proxy probe',
    senderName: 'M0-Probe',
    timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
  );
  final bytes = packet.writeTo();
  stdout.writeln('channel name="${channel.name}" hash='
      '0x${CryptoUtils.sha256(channel.secret)[0].toRadixString(16).padLeft(2, '0')}');
  stdout.writeln('transmitting via CMD_SEND_RAW_PACKET ...');
  try {
    await link.sendRawPacket(bytes);
  } catch (e) {
    stdout.writeln('raw TX failed: $e');
    return null;
  }
  return packet;
}

String _randomChannelName(Random rng) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return List<String>.generate(16, (_) => chars[rng.nextInt(chars.length)])
      .join();
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// HIL peer driver for OpenHop/stock companions. This is an ordinary companion
// client: it never changes radio settings. Peers sharing one physical radio
// must serialize their transmissions.
//
//   dart run tool/hil_peer.dart <command> <host> <port> [args]
//
// Commands:
//   handshake
//   export-self <outfile>          export this peer's advert blob (public)
//   import-contact <file>          import an advert blob
//   add-contact <key64> <name> [--flags N] [--type N]
//   remove-contact <key64>
//   contacts
//   channels
//   set-channel <idx> <name> <pskHex16>
//   dm <keyOrPrefix> <text> [--type N] [--await-ack secs]
//   channel <idx> <text>
//   binary <key64> <hex>
//   control <hex>
//   telemetry <key64>
//   discover <key64>
//   share <key64>
//   raw-packet <hex> [--priority N]
//   cli <keyOrPrefix> <command>   DM with txt type CLI_COMMAND (3)
//   drain [--max N]
//   watch [--secs N] [--filter text]
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

import 'src/hil_protocol.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('usage: hil_peer <command> <host> <port> [args]');
    exit(2);
  }
  final command = args[0];
  final host = args[1];
  final port = int.parse(args[2]);
  final rest = args.sublist(3);

  final conn = HilConnection(host, port);
  await conn.connect();
  try {
    await conn.handshake(appVersion: appProtocolVersion);
    _emit({
      'peer': {
        'name': _selfName(conn),
        'pubkey': conn.publicKey == null ? null : bytesToHex(conn.publicKey!),
        'fw': conn.deviceInfo?.firmwareVerCode,
        'maxChannels': conn.deviceInfo?.maxChannels,
        'maxContacts': conn.deviceInfo?.maxContacts,
      },
    });
    switch (command) {
      case 'handshake':
        break;
      case 'export-self':
        await _exportSelf(conn, rest);
      case 'import-contact':
        await _importContact(conn, rest);
      case 'add-contact':
        await _addContact(conn, rest);
      case 'remove-contact':
        await _removeContact(conn, rest);
      case 'contacts':
        await _contacts(conn);
      case 'channels':
        await _channels(conn);
      case 'set-channel':
        await _setChannel(conn, rest);
      case 'dm':
        await _dm(conn, rest);
      case 'channel':
        await _channelMessage(conn, rest);
      case 'binary':
        await _binary(conn, rest);
      case 'control':
        await _control(conn, rest);
      case 'telemetry':
        await _telemetry(conn, rest);
      case 'discover':
        await _discover(conn, rest);
      case 'share':
        await _share(conn, rest);
      case 'raw-packet':
        await _rawPacket(conn, rest);
      case 'cli':
        await _dm(conn, [...rest, '--type', '$txtTypeCliCommand']);
      case 'drain':
        await _drain(conn, rest);
      case 'watch':
        await _watch(conn, rest);
      default:
        stderr.writeln('unknown command "$command"');
        exit(2);
    }
  } finally {
    await conn.close();
  }
  exit(0);
}

void _emit(Map<String, Object?> value) => stdout.writeln(jsonEncode(value));

String _selfName(HilConnection conn) {
  // SELF_INFO was captured in the handshake reply; no accessor kept, so read
  // the last APP_START response from the frame log.
  for (final frame in conn.log.reversed) {
    if (frame.code == respCodeSelfInfo && frame.payload.length >= 59) {
      return cstring(frame.payload, 58);
    }
  }
  return '';
}

Future<void> _exportSelf(HilConnection conn, List<String> args) async {
  if (args.isEmpty) throw ArgumentError('export-self needs an outfile');
  conn.send([cmdExportContact]);
  final reply = await conn.next(timeout: const Duration(seconds: 10));
  if (reply.code != respCodeExportContact) {
    _emit({'ok': false, 'error': 'export failed: ${reply.hex}'});
    return;
  }
  final blob = reply.payload.sublist(1);
  await File(args.first).writeAsBytes(blob, flush: true);
  _emit({
    'ok': true,
    'bytes': blob.length,
    'sha256': bytesToHex(CryptoUtils.sha256(blob)),
    'blob': bytesToHex(blob),
  });
}

Future<void> _importContact(HilConnection conn, List<String> args) async {
  if (args.isEmpty) throw ArgumentError('import-contact needs a file');
  final blob = await File(args.first).readAsBytes();
  conn.send([cmdImportContact, ...blob]);
  final reply = await conn.next(timeout: const Duration(seconds: 10));
  _emit({'ok': reply.code == respCodeOk, 'reply': reply.hex});
}

Future<void> _addContact(HilConnection conn, List<String> args) async {
  if (args.length < 2) throw ArgumentError('add-contact <key64> <name>');
  final key = parseHex(args[0]);
  if (key.length != pubKeySize) throw ArgumentError('key must be 32 bytes');
  var flags = 0;
  var advType = advTypeChat;
  for (var i = 2; i < args.length; i++) {
    switch (args[i]) {
      case '--flags':
        flags = int.parse(args[++i]);
      case '--type':
        advType = int.parse(args[++i]);
    }
  }
  final name = utf8.encode(args[1]);
  final paddedName = Uint8List(maxNameSize);
  paddedName.setRange(0, name.length.clamp(0, maxNameSize - 1), name);
  final w = BufferWriter()
    ..writeByte(cmdAddUpdateContact)
    ..writeBytes(key)
    ..writeByte(advType)
    ..writeByte(flags)
    ..writeByte(0xFF) // unknown outbound path
    ..writeBytes(Uint8List(maxPathSize))
    ..writeBytes(paddedName)
    ..writeUInt32Le(0)
    ..writeInt32Le(0)
    ..writeInt32Le(0)
    ..writeUInt32Le(0);
  conn.send(w.toBytes());
  final reply = await conn.next(timeout: const Duration(seconds: 10));
  _emit({'ok': reply.code == respCodeOk, 'reply': reply.hex});
}

Future<void> _removeContact(HilConnection conn, List<String> args) async {
  final key = parseHex(args.first);
  conn.send([cmdRemoveContact, ...key]);
  final reply = await conn.next(timeout: const Duration(seconds: 10));
  _emit({'ok': reply.code == respCodeOk, 'reply': reply.hex});
}

Future<void> _contacts(HilConnection conn) async {
  conn.send([cmdGetContacts, 0, 0, 0, 0]);
  final frames = await conn.collect(
    quiet: const Duration(milliseconds: 500),
    timeout: const Duration(seconds: 30),
  );
  final contacts = <Map<String, Object?>>[];
  for (final f in frames) {
    if (f.code == respCodeContact) contacts.add(parseContact(f.payload));
  }
  _emit({'count': contacts.length, 'contacts': contacts});
}

Future<void> _channels(HilConnection conn) async {
  final max = conn.deviceInfo?.maxChannels ?? 40;
  final channels = <Map<String, Object?>>[];
  for (var i = 0; i < max; i++) {
    conn.send([cmdGetChannel, i]);
    final reply = await conn.next(timeout: const Duration(seconds: 3));
    if (reply.code == respCodeChannelInfo) {
      final parsed = parseChannel(reply.payload);
      if ((parsed['name'] as String).isNotEmpty ||
          parsed['psk'] != '00000000000000000000000000000000') {
        channels.add(parsed);
      }
    }
  }
  _emit({'count': channels.length, 'channels': channels});
}

Future<void> _setChannel(HilConnection conn, List<String> args) async {
  final idx = int.parse(args[0]);
  final name = args[1];
  final psk = parseHex(args[2]);
  final nameBytes = utf8.encode(name);
  final paddedName = Uint8List(maxNameSize);
  paddedName.setRange(0, nameBytes.length.clamp(0, maxNameSize - 1), nameBytes);
  conn.send([cmdSetChannel, idx, ...paddedName, ...psk]);
  final reply = await conn.next(timeout: const Duration(seconds: 10));
  _emit({'ok': reply.code == respCodeOk, 'reply': reply.hex});
}

Future<void> _dm(HilConnection conn, List<String> args) async {
  if (args.length < 2) throw ArgumentError('dm <keyOrPrefix> <text>');
  final keyBytes = parseHex(args[0]);
  final prefix = keyBytes.length >= 6 ? keyBytes.sublist(0, 6) : keyBytes;
  var txtType = txtTypePlain;
  var awaitAck = Duration.zero;
  for (var i = 2; i < args.length; i++) {
    switch (args[i]) {
      case '--type':
        txtType = int.parse(args[++i]);
      case '--await-ack':
        awaitAck = Duration(seconds: int.parse(args[++i]));
    }
  }
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  conn.send([
    cmdSendTxtMsg,
    txtType,
    0,
    ts & 0xFF,
    (ts >> 8) & 0xFF,
    (ts >> 16) & 0xFF,
    (ts >> 24) & 0xFF,
    ...prefix,
    ...utf8.encode(args[1]),
    0,
  ]);
  final reply = await conn.next(timeout: const Duration(seconds: 10));
  Map<String, Object?> out = {
    'command': 'dm',
    'sent': args[1],
    'code': reply.code,
    'reply': reply.hex,
  };
  if (reply.code == respCodeSent && reply.payload.length >= 10) {
    final ack =
        ByteData.sublistView(reply.payload, 2, 6).getUint32(0, Endian.little);
    out['expectedAck'] = ack;
    out['flood'] = reply.payload[1] == 1;
    out['timeoutMs'] =
        ByteData.sublistView(reply.payload, 6, 10).getUint32(0, Endian.little);
    if (awaitAck > Duration.zero) {
      final deadline = DateTime.now().add(awaitAck);
      var confirmed = false;
      while (DateTime.now().isBefore(deadline)) {
        try {
          final frame = await conn.next(
              timeout: deadline.difference(DateTime.now()),
              includePushes: true);
          if (frame.code == pushCodeSendConfirmed &&
              frame.payload.length >= 5) {
            final got = ByteData.sublistView(frame.payload, 1, 5)
                .getUint32(0, Endian.little);
            if (got == ack) {
              confirmed = true;
              break;
            }
          }
        } on TimeoutException {
          break;
        }
      }
      out['confirmed'] = confirmed;
    }
  }
  _emit(out);
}

Future<void> _channelMessage(HilConnection conn, List<String> args) async {
  final idx = int.parse(args[0]);
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  conn.send([
    cmdSendChannelTxtMsg,
    txtTypePlain,
    idx,
    ts & 0xFF,
    (ts >> 8) & 0xFF,
    (ts >> 16) & 0xFF,
    (ts >> 24) & 0xFF,
    ...utf8.encode(args[1]),
    0,
  ]);
  final reply = await conn.next(timeout: const Duration(seconds: 10));
  _emit(
      {'ok': reply.code == respCodeOk, 'code': reply.code, 'reply': reply.hex});
}

Future<void> _binary(HilConnection conn, List<String> args) async {
  final key = parseHex(args[0]);
  conn.send([cmdSendBinaryReq, ...key, ...parseHex(args[1])]);
  final reply = await conn.next(timeout: const Duration(seconds: 10));
  _emit({'code': reply.code, 'reply': reply.hex});
}

Future<void> _control(HilConnection conn, List<String> args) async {
  conn.send([cmdSendControlData, ...parseHex(args[0])]);
  final reply = await conn.next(timeout: const Duration(seconds: 10));
  _emit({'code': reply.code, 'reply': reply.hex});
}

Future<void> _telemetry(HilConnection conn, List<String> args) async {
  final key = parseHex(args[0]);
  conn.send([cmdSendTelemetryReq, 0, 0, 0, ...key]);
  final reply = await conn.next(timeout: const Duration(seconds: 10));
  _emit({'code': reply.code, 'reply': reply.hex});
}

Future<void> _discover(HilConnection conn, List<String> args) async {
  final key = parseHex(args[0]);
  conn.send([cmdSendPathDiscoveryReq, 0, ...key]);
  final reply = await conn.next(timeout: const Duration(seconds: 10));
  _emit({'code': reply.code, 'reply': reply.hex});
}

Future<void> _share(HilConnection conn, List<String> args) async {
  final key = parseHex(args[0]);
  conn.send([cmdShareContact, ...key]);
  final reply = await conn.next(timeout: const Duration(seconds: 10));
  _emit({'code': reply.code, 'reply': reply.hex});
}

Future<void> _rawPacket(HilConnection conn, List<String> args) async {
  var priority = 0;
  if (args.contains('--priority')) {
    priority = int.parse(args[args.indexOf('--priority') + 1]);
  }
  conn.send([cmdSendRawPacket, priority, ...parseHex(args.first)]);
  final reply = await conn.next(timeout: const Duration(seconds: 10));
  _emit({'code': reply.code, 'reply': reply.hex});
}

Future<void> _drain(HilConnection conn, List<String> args) async {
  final max =
      args.contains('--max') ? int.parse(args[args.indexOf('--max') + 1]) : 50;
  final messages = <Map<String, Object?>>[];
  for (var i = 0; i < max; i++) {
    conn.send([cmdSyncNextMessage]);
    final reply = await conn.next(timeout: const Duration(seconds: 5));
    final parsed = parseQueuedMessage(reply.payload);
    if (parsed['empty'] == true) break;
    parsed['hex'] = reply.hex;
    messages.add(parsed);
  }
  _emit({'count': messages.length, 'messages': messages});
}

Future<void> _watch(HilConnection conn, List<String> args) async {
  var secs = 30;
  String? filter;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--secs':
        secs = int.parse(args[++i]);
      case '--filter':
        filter = args[++i];
    }
  }
  final end = DateTime.now().add(Duration(seconds: secs));
  while (DateTime.now().isBefore(end)) {
    try {
      final frame = await conn.next(
        timeout: end.difference(DateTime.now()),
        includePushes: true,
      );
      if (frame.isPush) {
        final entry = _describePush(frame);
        final encoded = jsonEncode(entry);
        if (filter == null ||
            encoded.toLowerCase().contains(filter.toLowerCase())) {
          stdout.writeln(encoded);
        }
      } else {
        final entry = frame.toJson();
        final encoded = jsonEncode(entry);
        if (filter == null ||
            encoded.toLowerCase().contains(filter.toLowerCase())) {
          stdout.writeln(encoded);
        }
      }
    } on TimeoutException {
      break;
    }
  }
}

Map<String, Object?> _describePush(HilFrame frame) {
  final f = frame.payload;
  final base = <String, Object?>{
    't': frame.at.toIso8601String(),
    'push': '0x${frame.code.toRadixString(16)}',
    'len': f.length,
    'hex': frame.hex,
  };
  if (frame.code == pushCodeLogRxData && f.length >= 4) {
    final snr = (f[1] >= 0x80 ? f[1] - 0x100 : f[1]) / 4.0;
    final rssi = f[2] >= 0x80 ? f[2] - 0x100 : f[2];
    final raw = Uint8List.fromList(f.sublist(3));
    final packet = Packet.readFrom(raw);
    base['snr'] = snr;
    base['rssi'] = rssi;
    base['packet'] = bytesToHex(raw);
    if (packet != null) {
      base['payloadType'] = packet.payloadType;
      base['routeType'] = packet.routeType;
      base['pathLen'] = packet.pathLenByte;
      base['path'] = bytesToHex(packet.path);
      base['payload'] = bytesToHex(packet.payload);
    }
  } else if (frame.code == pushCodeSendConfirmed && f.length >= 5) {
    base['ack'] = ByteData.sublistView(f, 1, 5).getUint32(0, Endian.little);
  } else if (frame.code == pushCodeMsgWaiting) {
    base['msgWaiting'] = true;
  } else if (frame.code == pushCodeAdvert && f.length >= 33) {
    base['pubkey'] = bytesToHex(f.sublist(1, 33));
  } else if (frame.code == pushCodeNewAdvert && f.length >= 34) {
    base['pubkey'] = bytesToHex(f.sublist(2, 34));
  } else if (frame.code == pushCodeTelemetryResponse && f.length >= 7) {
    base['prefix'] = bytesToHex(f.sublist(2, 8));
    base['data'] = bytesToHex(f.sublist(8));
  } else if (frame.code == pushCodeBinaryResponse && f.length >= 2) {
    base['tag'] = f[1];
    base['data'] = bytesToHex(f.sublist(2));
  } else if (frame.code == pushCodeControlData && f.length >= 4) {
    base['pathLen'] = f[3];
    base['data'] = bytesToHex(f.sublist(4));
  } else if (frame.code == pushCodeRawData && f.length >= 3) {
    base['data'] = bytesToHex(f.sublist(3));
  }
  return base;
}

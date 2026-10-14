// Read-only inspector for a MeshCore companion over TCP.
//
//   dart run tool/companion_inspect.dart <host> <port> [channels|contacts|messages|all]
//
// Connects as an ordinary companion client (the same handshake meshcore-open
// performs) and prints the requested state. It never transmits on the mesh and
// never changes any setting. Note the companion protocol is single-client, so
// running this can detach whatever client is currently attached to the target.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: companion_inspect <host> <port> '
        '[channels|contacts|messages|all] [message-filter] [max-messages]');
    exit(2);
  }
  final host = args[0];
  final port = int.parse(args[1]);
  final what = args.length > 2 ? args[2] : 'all';
  final filter = args.length > 3 ? args[3] : '';
  final maxMessages = args.length > 4 ? int.parse(args[4]) : 50;

  final socket = await Socket.connect(host, port,
      timeout: const Duration(seconds: 10));
  socket.setOption(SocketOption.tcpNoDelay, true);

  final codec = SerialFrameCodec();
  final buffer = <Uint8List>[];
  final waiters = <Completer<Uint8List>>[];
  socket.listen((data) {
    for (final frame in codec.ingest(data)) {
      if (waiters.isNotEmpty) {
        waiters.removeAt(0).complete(frame);
      } else {
        buffer.add(frame);
      }
    }
  });

  Future<Uint8List> next(Duration timeout) {
    if (buffer.isNotEmpty) return Future.value(buffer.removeAt(0));
    final c = Completer<Uint8List>();
    waiters.add(c);
    return c.future.timeout(timeout, onTimeout: () => Uint8List(0));
  }

  Future<Uint8List> nextDefault() => next(const Duration(seconds: 5));

  void send(List<int> payload) =>
      socket.add(codec.encodeFrame(payload, prefix: frameInboundPrefix));

  try {
    send([cmdDeviceQuery, appProtocolVersion]);
    final deviceInfo = await nextDefault();
    final maxChannels = deviceInfo.length > 3 ? deviceInfo[3] : 0;
    stdout.writeln('DEVICE_INFO fw=${deviceInfo[1]} '
        'maxContacts=${deviceInfo[2] * 2} maxChannels=$maxChannels');

    // CMD_APP_START needs len>=8 (6 reserved bytes then trailing app name).
    send([cmdAppStart, appProtocolVersion, 0, 0, 0, 0, 0, 0,
      ...'CompanionInspect'.codeUnits, 0]);
    var self = await nextDefault();
    var guard = 0;
    while (self.isNotEmpty &&
        self[0] != respCodeSelfInfo &&
        self[0] != respCodeErr &&
        guard++ < 10) {
      stdout.writeln('  (ignoring frame 0x${self[0].toRadixString(16)} '
          'len=${self.length})');
      self = await nextDefault();
    }
    if (self.length < 59) {
      stderr.writeln('SELF_INFO unexpected (${self.length} bytes: '
          '${bytesToHex(self)})');
      exit(1);
    }
    final pubkey = self.sublist(4, 36);
    final freqKhz =
        ByteData.sublistView(self, 48, 52).getUint32(0, Endian.little);
    final name = String.fromCharCodes(
        self.sublist(58).takeWhile((b) => b != 0));
    stdout.writeln('SELF_INFO name="$name" pubkey=${bytesToHex(pubkey)} '
        'freq=${freqKhz * 1000}Hz');

    if (what == 'channels' || what == 'all') {
      await _dumpChannels(send, next, maxChannels);
    }
    if (what == 'contacts' || what == 'all') {
      await _dumpContacts(send, next);
    }
    if (what == 'messages' || what == 'all') {
      await _dumpMessages(send, next, max: maxMessages, filter: filter);
    }
  } finally {
    await socket.close();
  }
}

Future<void> _dumpChannels(
  void Function(List<int>) send,
  Future<Uint8List> Function(Duration) next,
  int maxChannels,
) async {
  stdout.writeln('--- channels ($maxChannels) ---');
  send([cmdGetChannel]); // empty payload == full list
  for (var i = 0; i < maxChannels; i++) {
    final frame = await next(const Duration(seconds: 2));
    if (frame.isEmpty) break;
    if (frame[0] != respCodeChannelInfo || frame.length < 50) {
      stdout.writeln('  unexpected frame 0x${frame[0].toRadixString(16)} '
          'len=${frame.length}');
      continue;
    }
    final idx = frame[1];
    final name = String.fromCharCodes(
        frame.sublist(2, 34).takeWhile((b) => b != 0)).trim();
    final secret = frame.sublist(34, 50);
    final hash = CryptoUtils.sha256(Uint8List.fromList(secret))[0];
    stdout.writeln('  [$idx] name="$name" psk=${bytesToHex(secret)} '
        'hash=0x${hash.toRadixString(16).padLeft(2, '0')}');
  }
}

Future<void> _dumpContacts(
  void Function(List<int>) send,
  Future<Uint8List> Function(Duration) next,
) async {
  stdout.writeln('--- contacts ---');
  send([cmdGetContacts, 0, 0, 0, 0]);
  final start = await next(const Duration(seconds: 5));
  if (start.isEmpty || start[0] != respCodeContactsStart) {
    stdout.writeln('  unexpected start frame');
    return;
  }
  final count = BufferReader(start)..skipBytes(1);
  final n = count.readUInt32Le();
  stdout.writeln('  count=$n');
  for (var i = 0; i < n; i++) {
    final c = await next(const Duration(seconds: 3));
    if (c.isEmpty || c[0] != respCodeContact) {
      stdout.writeln('  unexpected contact frame');
      break;
    }
    final pubkey = c.sublist(1, 33);
    final advType = c[33];
    final flags = c[34];
    final pathLen = c[35];
    final nameStart = 36 + maxPathSize;
    final name = String.fromCharCodes(
        c.sublist(nameStart, nameStart + maxNameSize)
            .takeWhile((b) => b != 0)).trim();
    stdout.writeln('  ${bytesToHex(pubkey.sublist(0, 6))} "$name" '
        'advType=$advType flags=0x${flags.toRadixString(16)} pathLen=$pathLen');
  }
  await next(const Duration(seconds: 5)); // END_OF_CONTACTS
}

Future<void> _dumpMessages(
  void Function(List<int>) send,
  Future<Uint8List> Function(Duration) next, {
  int max = 50,
  String filter = '',
}) async {
  stdout.writeln('--- queued messages (max $max, filter="$filter") ---');
  var total = 0;
  var matches = 0;
  for (var i = 0; i < max; i++) {
    send([cmdSyncNextMessage]);
    final frame = await next(const Duration(seconds: 3));
    if (frame.isEmpty) break;
    if (frame[0] == respCodeNoMoreMessages) {
      stdout.writeln('  (no more after $total)');
      break;
    }
    total++;
    String? line;
    if (frame[0] == respCodeChannelMsgRecvV3) {
      final r = BufferReader(frame)..skipBytes(4);
      final idx = r.readByte();
      r.skipBytes(1); // path len
      r.skipBytes(1); // txt type
      r.skipBytes(4); // timestamp
      line = 'channel[$idx]: ${r.readCString()}';
    } else if (frame[0] == respCodeContactMsgRecvV3) {
      final r = BufferReader(frame)..skipBytes(4);
      final sender = r.readBytes(6);
      r.skipBytes(1);
      r.skipBytes(1);
      r.skipBytes(4);
      line = 'dm from ${bytesToHex(sender)}: ${r.readCString()}';
    } else {
      line = 'frame 0x${frame[0].toRadixString(16)} len=${frame.length}';
    }
    if (filter.isEmpty) {
      stdout.writeln('  $line');
    } else if (line.toLowerCase().contains(filter.toLowerCase())) {
      matches++;
      stdout.writeln('  MATCH @$total: $line');
    }
  }
  if (filter.isNotEmpty) {
    stdout.writeln('drained $total message(s); $matches match "$filter"');
  }
}

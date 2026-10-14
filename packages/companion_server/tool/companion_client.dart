// Small laptop-side client for the M0 background-execution spike.
//
// Connects to a running companion proxy over TCP and runs the same handshake
// meshcore-open performs, so you can verify the proxy is still reachable while
// the app is backgrounded (or while the phone is idle/dozing):
//
//   dart run tool/companion_client.dart <host> <port>
//
// Read-only: it never transmits on the mesh.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: companion_client <host> <port>');
    exit(2);
  }
  final host = args[0];
  final port = int.parse(args[1]);

  stdout.writeln('connecting $host:$port ...');
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

  Future<Uint8List> next({Duration timeout = const Duration(seconds: 5)}) {
    if (buffer.isNotEmpty) return Future.value(buffer.removeAt(0));
    final c = Completer<Uint8List>();
    waiters.add(c);
    return c.future.timeout(timeout);
  }

  void send(List<int> payload) =>
      socket.add(codec.encodeFrame(payload, prefix: frameInboundPrefix));

  try {
    // Handshake, exactly as meshcore-open does.
    send([cmdDeviceQuery, appProtocolVersion]);
    final deviceInfo = await next();
    stdout.writeln('DEVICE_INFO code=${deviceInfo[0]} fw=${deviceInfo[1]} '
        'maxContacts=${deviceInfo[2] * 2} maxChannels=${deviceInfo[3]}');

    send([cmdAppStart, appProtocolVersion]);
    final selfInfo = await next();
    if (selfInfo.length < 59) {
      stderr.writeln('SELF_INFO too short (${selfInfo.length} bytes)');
      exit(1);
    }
    final pubkey = selfInfo.sublist(4, 36);
    // SELF_INFO reports frequency in kHz; normalise to Hz for display.
    final freq =
        ByteData.sublistView(selfInfo, 48, 52).getUint32(0, Endian.little) * 1000;
    final nameBytes = <int>[];
    for (var i = 58; i < selfInfo.length && selfInfo[i] != 0; i++) {
      nameBytes.add(selfInfo[i]);
    }
    final name = String.fromCharCodes(nameBytes);
    stdout.writeln('SELF_INFO code=${selfInfo[0]} name="$name" '
        'freq=${freq}Hz pubkey=${bytesToHex(pubkey.sublist(0, 4))}');

    send([cmdGetBattAndStorage]);
    stdout.writeln('BATT_AND_STORAGE code=${(await next())[0]}');

    send([cmdGetCustomVars]);
    stdout.writeln('CUSTOM_VARS code=${(await next())[0]}');

    send([cmdGetAutoAddConfig]);
    stdout.writeln('AUTOADD_CONFIG code=${(await next())[0]}');

    send([cmdGetContacts, 0, 0, 0, 0]);
    final contactsStart = await next();
    final cr = BufferReader(contactsStart)..skipBytes(1);
    stdout.writeln('CONTACTS_START code=${contactsStart[0]} '
        'count=${cr.readUInt32Le()}');

    stdout.writeln('OK: proxy reachable');
  } finally {
    await socket.close();
  }
}

// Probe whether a stock companion accepts a raw-packet companion frame larger
// than the 176-byte payload limit. Uses a random throwaway channel (never
// Public or a named channel) and sends exactly one frame per size.
//
//   dart run tool/hil_raw_tx_probe.dart <host> <port> [size ...]
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: hil_raw_tx_probe <host> <port> [size ...]');
    exit(2);
  }
  final host = args[0];
  final port = int.parse(args[1]);
  final sizes =
      args.length > 2 ? args.skip(2).map(int.parse).toList() : [157, 165];
  final rng = Random.secure();
  final channel = Channel(
    name: List<String>.generate(
            16, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[rng.nextInt(36)])
        .join(),
    secret: Uint8List.fromList(List<int>.generate(16, (_) => rng.nextInt(256))),
  );
  final socket =
      await Socket.connect(host, port, timeout: const Duration(seconds: 10));
  final codec = SerialFrameCodec(direction: FrameDirection.outbound);
  final replies = <Uint8List>[];
  socket.listen((data) => replies.addAll(codec.ingest(data)));
  await Future<void>.delayed(const Duration(milliseconds: 300));
  for (final size in sizes) {
    final data = Uint8List.fromList(
        List<int>.generate(size, (i) => (i * 7 + 11) & 0xFF));
    final packet = PacketBuilder.createGroupData(
      channel: channel,
      dataType: 0x4849,
      data: data,
    );
    final bytes = packet.writeTo();
    final payload = [cmdSendRawPacket, 0, ...bytes];
    final frame = Uint8List.fromList([
      frameInboundPrefix,
      payload.length & 0xFF,
      (payload.length >> 8) & 0xFF,
      ...payload,
    ]);
    stdout.writeln('size=$size packet=${bytes.length} frame=${frame.length}');
    socket.add(frame);
    await socket.flush();
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (replies.isEmpty) {
      stdout.writeln('  no reply within 3s');
    } else {
      stdout.writeln('  replies=${replies.map(bytesToHex).toList()}');
      replies.clear();
    }
    // Liveness after the probe frame.
    socket.add(codec.encodeFrame(
      [cmdDeviceQuery, appProtocolVersion],
      prefix: frameInboundPrefix,
    ));
    final live = DateTime.now().add(const Duration(seconds: 3));
    Uint8List? info;
    while (DateTime.now().isBefore(live) && info == null) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      for (final frame in replies) {
        if (frame.isNotEmpty && frame[0] == respCodeDeviceInfo) info = frame;
      }
      if (info != null) break;
    }
    stdout.writeln('  liveness=${info == null ? 'FAIL' : 'ok'}');
    replies.clear();
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  await socket.close();
  exit(0);
}

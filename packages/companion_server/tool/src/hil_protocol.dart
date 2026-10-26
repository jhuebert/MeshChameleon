// Shared companion-protocol client used by the HIL tools.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

class HilFrame {
  HilFrame(this.payload, {DateTime? at}) : at = at ?? DateTime.now().toUtc();

  final Uint8List payload;
  final DateTime at;

  int get code => payload.isEmpty ? -1 : payload[0];
  bool get isPush => code >= 0x80;
  String get hex => bytesToHex(payload);

  Map<String, Object?> toJson() => {
        't': at.toIso8601String(),
        'code': code,
        'push': isPush,
        'len': payload.length,
        'hex': hex,
      };

  @override
  String toString() => 'HilFrame(code=0x${code.toRadixString(16)} '
      'len=${payload.length} hex=$hex)';
}

/// Companion-protocol TCP client with frame queueing, tolerant of pushes
/// interleaving with command replies.
class HilConnection {
  HilConnection(this.host, this.port);

  final String host;
  final int port;
  final SerialFrameCodec _codec = SerialFrameCodec.bidirectional();
  final List<HilFrame> _buffer = <HilFrame>[];
  final List<Completer<HilFrame>> _waiters = <Completer<HilFrame>>[];
  final List<HilFrame> log = <HilFrame>[];
  Socket? _socket;
  int appTargetVer = appProtocolVersion;
  DeviceInfo? deviceInfo;
  Uint8List? publicKey;

  void Function(HilFrame frame)? onFrame;

  bool get connected => _socket != null;

  Future<void> connect() async {
    final socket =
        await Socket.connect(host, port, timeout: const Duration(seconds: 10));
    socket.setOption(SocketOption.tcpNoDelay, true);
    _codec.reset();
    _socket = socket;
    socket.listen((data) {
      for (final payload in _codec.ingest(data)) {
        final frame = HilFrame(payload);
        log.add(frame);
        onFrame?.call(frame);
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).complete(frame);
        } else {
          _buffer.add(frame);
        }
      }
    }, onError: (Object e) {
      for (final w in _waiters) {
        if (!w.isCompleted) w.completeError(e);
      }
      _waiters.clear();
    }, onDone: () {
      for (final w in _waiters) {
        if (!w.isCompleted) {
          w.completeError(const SocketException('connection closed'));
        }
      }
      _waiters.clear();
      _socket = null;
    });
  }

  Future<void> close() async {
    final socket = _socket;
    _socket = null;
    await socket?.close();
  }

  void send(List<int> payload) {
    final socket = _socket;
    if (socket == null) throw StateError('not connected');
    socket.add(_codec.encodeFrame(payload, prefix: frameInboundPrefix));
  }

  void sendHex(String hex) => send(parseHex(hex));

  /// Write raw bytes without framing (framing-negative tests).
  void sendRaw(List<int> bytes) {
    final socket = _socket;
    if (socket == null) throw StateError('not connected');
    socket.add(bytes);
  }

  Future<void> flush() async => _socket?.flush();

  Future<HilFrame> next({
    Duration timeout = const Duration(seconds: 5),
    bool includePushes = false,
  }) async {
    while (true) {
      if (_buffer.isNotEmpty) {
        final frame = _buffer.removeAt(0);
        if (frame.isPush && !includePushes) continue;
        return frame;
      }
      final completer = Completer<HilFrame>();
      _waiters.add(completer);
      final HilFrame frame;
      try {
        frame = await completer.future.timeout(timeout);
      } on TimeoutException {
        // Drop the stale waiter so the next frame is not delivered to it.
        _waiters.remove(completer);
        rethrow;
      }
      if (frame.isPush && !includePushes) continue;
      return frame;
    }
  }

  /// Drop any already-buffered replies/pushes before a new command.
  Future<void> quiesce(
      {Duration quiet = const Duration(milliseconds: 40)}) async {
    while (true) {
      try {
        await next(timeout: quiet, includePushes: true);
      } on TimeoutException {
        return;
      }
    }
  }

  /// Collect frames until [quiet] elapses with no new frame, or [timeout].
  Future<List<HilFrame>> collect({
    Duration quiet = const Duration(milliseconds: 250),
    Duration timeout = const Duration(seconds: 5),
    bool includePushes = true,
  }) async {
    final out = <HilFrame>[];
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      try {
        final frame = await next(
          timeout: remaining < quiet ? remaining : quiet,
          includePushes: includePushes,
        );
        out.add(frame);
      } on TimeoutException {
        break;
      }
    }
    return out;
  }

  /// Send one command and return the first non-push reply.
  Future<HilFrame> request(
    List<int> payload, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    send(payload);
    return next(timeout: timeout);
  }

  Future<HilFrame> requestHex(
    String hex, {
    Duration timeout = const Duration(seconds: 5),
  }) =>
      request(parseHex(hex), timeout: timeout);

  Future<void> handshake({int appVersion = appProtocolVersion}) async {
    appTargetVer = appVersion;
    final info = await request([cmdDeviceQuery, appVersion]);
    deviceInfo = TcpDeviceInfoParser.parse(info.payload);
    final self = await request([
      cmdAppStart,
      appVersion,
      0,
      0,
      0,
      0,
      0,
      0,
      ...utf8.encode('HILClient'),
      0,
    ]);
    if (self.code == respCodeSelfInfo && self.payload.length >= 36) {
      publicKey = Uint8List.fromList(self.payload.sublist(4, 36));
    }
    // Drain the startup battery read performed by some clients (none here).
  }
}

/// Local parser mirroring TcpDeviceLink.parseDeviceInfo.
class TcpDeviceInfoParser {
  static DeviceInfo parse(Uint8List frame) {
    if (frame.length < 4) {
      throw const FormatException('truncated DEVICE_INFO');
    }
    String cstring(int start, int len) {
      if (frame.length < start + len) return '';
      final bytes = frame.sublist(start, start + len);
      final end = bytes.indexOf(0);
      return String.fromCharCodes(end >= 0 ? bytes.sublist(0, end) : bytes)
          .trim();
    }

    return DeviceInfo(
      firmwareVerCode: frame[1],
      maxContacts: frame[2] * 2,
      maxChannels: frame[3],
      manufacturer: cstring(20, 40),
      version: cstring(60, 20),
      clientRepeat: frame.length >= 81 ? frame[80] : 0,
      pathHashMode: frame.length >= 82 ? (frame[81] & 0xFF).clamp(0, 3) : 0,
    );
  }
}

Uint8List parseHex(String input) {
  final clean = input.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (clean.length.isOdd) {
    throw FormatException('odd-length hex: $input');
  }
  return Uint8List.fromList([
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}

String cstring(List<int> bytes, [int start = 0, int? end]) {
  final slice = bytes.sublist(start, end ?? bytes.length);
  final nul = slice.indexOf(0);
  return String.fromCharCodes(nul >= 0 ? slice.sublist(0, nul) : slice);
}

/// Parse one `RESP_CODE_CONTACT` frame body.
Map<String, Object?> parseContact(Uint8List f) {
  final pubkey = f.sublist(1, 33);
  final nameStart = 36 + maxPathSize;
  return {
    'pubkey': bytesToHex(pubkey),
    'prefix': bytesToHex(pubkey.sublist(0, 6)),
    'advType': f[33],
    'flags': f[34],
    'pathLen': f[35],
    'name': cstring(f, nameStart, nameStart + maxNameSize).trim(),
    'lastAdvert': ByteData.sublistView(
            f, nameStart + maxNameSize, nameStart + maxNameSize + 4)
        .getUint32(0, Endian.little),
    'lastmod': ByteData.sublistView(
            f, nameStart + maxNameSize + 12, nameStart + maxNameSize + 16)
        .getUint32(0, Endian.little),
  };
}

/// Parse one `RESP_CODE_CHANNEL_INFO` frame body.
Map<String, Object?> parseChannel(Uint8List f) => {
      'index': f[1],
      'name': cstring(f, 2, 34).trim(),
      'psk': bytesToHex(f.sublist(34, 50)),
    };

/// Parse a V3 queued-message frame.
Map<String, Object?> parseQueuedMessage(Uint8List f) {
  final code = f[0];
  if (code == respCodeNoMoreMessages) return {'empty': true};
  if (code == respCodeContactMsgRecvV3) {
    return {
      'kind': 'dm',
      'sender': bytesToHex(f.sublist(4, 10)),
      'pathLen': f[10],
      'txtType': f[11],
      'timestamp': ByteData.sublistView(f, 12, 16).getUint32(0, Endian.little),
      'text': cstring(f, 16),
    };
  }
  if (code == respCodeChannelMsgRecvV3) {
    return {
      'kind': 'channel',
      'channel': f[4],
      'pathLen': f[5],
      'txtType': f[6],
      'timestamp': ByteData.sublistView(f, 7, 11).getUint32(0, Endian.little),
      'text': cstring(f, 11),
    };
  }
  return {'kind': 'other', 'code': code, 'len': f.length};
}

String jsonLine(Map<String, Object?> value) => jsonEncode(value);

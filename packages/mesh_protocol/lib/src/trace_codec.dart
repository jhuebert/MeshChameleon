import 'dart:typed_data';

import 'buffer.dart';
import 'constants.dart';

/// A trace request/response payload: `tag(4) | auth(4) | flags | path`.
class TracePayload {
  const TracePayload({
    required this.tag,
    required this.authCode,
    required this.flags,
    required this.path,
  });

  final int tag;
  final int authCode;
  final int flags;
  final Uint8List path;

  int get pathSize => flags & 0x03;

  /// Whether the path length is a whole number of hash entries and within the
  /// on-air path limit.
  bool get hasValidPath =>
      (path.length >> pathSize) <= maxPathSize &&
      path.length % (1 << pathSize) == 0;
}

/// Encode a trace payload.
Uint8List encodeTracePayload({
  required int tag,
  required int authCode,
  required int flags,
  List<int> path = const [],
}) =>
    (BufferWriter()
          ..writeUInt32Le(tag)
          ..writeUInt32Le(authCode)
          ..writeByte(flags & 0xFF)
          ..writeBytes(path))
        .toBytes();

/// Decode a trace payload, or null when it is shorter than the fixed header.
TracePayload? decodeTracePayload(Uint8List payload) {
  if (payload.length < 9) return null;
  final reader = BufferReader(payload);
  return TracePayload(
    tag: reader.readUInt32Le(),
    authCode: reader.readUInt32Le(),
    flags: reader.readByte(),
    path: Uint8List.fromList(reader.readRemainingBytes()),
  );
}

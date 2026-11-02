import 'dart:typed_data';

import 'buffer.dart';
import 'paths.dart';

/// The plaintext inside a returned-path packet:
/// `path_len | path bytes | extra_type | extra`.
class PathReturnPayload {
  const PathReturnPayload({
    required this.pathLenEncoded,
    required this.path,
    required this.extraType,
    required this.extra,
  });

  final int pathLenEncoded;
  final Uint8List path;
  final int extraType;
  final Uint8List extra;

  /// Whether the encoded path width/count are within the on-air limits.
  bool get hasValidPath => PathUtils.isValidPathLen(pathLenEncoded);
}

/// Encode the returned-path plaintext.
Uint8List encodePathReturnPayload({
  required int pathLenEncoded,
  required List<int> path,
  required int extraType,
  required List<int> extra,
}) =>
    (BufferWriter()
          ..writeByte(pathLenEncoded & 0xFF)
          ..writeBytes(path)
          ..writeByte(extraType & 0xFF)
          ..writeBytes(extra))
        .toBytes();

/// Decode the returned-path plaintext, or null when it is empty or truncated
/// before its extra-type byte.
PathReturnPayload? decodePathReturnPayload(Uint8List plaintext) {
  if (plaintext.isEmpty) return null;
  final pathLenEncoded = plaintext[0];
  final pathByteLen = PathUtils.getByteLength(pathLenEncoded);
  final extraStart = 1 + pathByteLen;
  if (plaintext.length <= extraStart) return null;
  return PathReturnPayload(
    pathLenEncoded: pathLenEncoded,
    path: Uint8List.fromList(plaintext.sublist(1, extraStart)),
    extraType: plaintext[extraStart],
    extra: Uint8List.fromList(plaintext.sublist(extraStart + 1)),
  );
}

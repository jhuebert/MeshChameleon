import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('round-trips the returned-path plaintext', () {
    final encoded = encodePathReturnPayload(
      pathLenEncoded: 0x02,
      path: [0xAA, 0xBB],
      extraType: payloadTypeAck,
      extra: [1, 2, 3, 4],
    );
    final decoded = decodePathReturnPayload(encoded);
    expect(decoded, isNotNull);
    expect(decoded!.pathLenEncoded, 0x02);
    expect(decoded.path, [0xAA, 0xBB]);
    expect(decoded.extraType, payloadTypeAck);
    expect(decoded.extra, [1, 2, 3, 4]);
    expect(decoded.hasValidPath, isTrue);
  });

  test('accepts a zero-hop route', () {
    final decoded = decodePathReturnPayload(
      encodePathReturnPayload(
        pathLenEncoded: 0,
        path: const [],
        extraType: payloadTypeAck,
        extra: [9, 9, 9, 9],
      ),
    );
    expect(decoded, isNotNull);
    expect(decoded!.path, isEmpty);
    expect(decoded.hasValidPath, isTrue);
  });

  test('returns null for empty or truncated plaintext', () {
    expect(decodePathReturnPayload(Uint8List(0)), isNull);
    // Path length 1 but no extra-type byte after the path.
    expect(decodePathReturnPayload(Uint8List.fromList([1, 0])), isNull);
  });

  test('keeps an overlong path for callers but marks it invalid', () {
    final path = List<int>.filled(126, 0xAA);
    final decoded = decodePathReturnPayload(
      encodePathReturnPayload(
        pathLenEncoded: 0x7F,
        path: path,
        extraType: payloadTypeResponse,
        extra: const [],
      ),
    );
    expect(decoded, isNotNull);
    expect(decoded!.path, path);
    expect(decoded.hasValidPath, isFalse);
  });
}

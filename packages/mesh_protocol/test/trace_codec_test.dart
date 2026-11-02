import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('round-trips the trace payload', () {
    final encoded = encodeTracePayload(
      tag: 0x01020304,
      authCode: 0x05060708,
      flags: 1,
      path: [0xAA, 0xBB],
    );
    final trace = decodeTracePayload(encoded);
    expect(trace, isNotNull);
    expect(trace!.tag, 0x01020304);
    expect(trace.authCode, 0x05060708);
    expect(trace.flags, 1);
    expect(trace.path, [0xAA, 0xBB]);
    expect(trace.pathSize, 1);
    expect(trace.hasValidPath, isTrue);
  });

  test('rejects payloads shorter than the fixed header', () {
    expect(decodeTracePayload(Uint8List(8)), isNull);
  });

  test('validates path width and length', () {
    TracePayload trace(int flags, int length) => TracePayload(
          tag: 0,
          authCode: 0,
          flags: flags,
          path: Uint8List(length),
        );

    expect(trace(0, 0).hasValidPath, isTrue);
    expect(trace(0, maxPathSize).hasValidPath, isTrue);
    expect(trace(0, maxPathSize + 1).hasValidPath, isFalse);
    expect(trace(1, 2).hasValidPath, isTrue);
    expect(trace(1, 3).hasValidPath, isFalse);
    expect(trace(2, 4).hasValidPath, isTrue);
    expect(trace(2, 6).hasValidPath, isFalse);
  });

  test('PacketBuilder.createTrace uses the shared encoding', () {
    final packet = PacketBuilder.createTrace(
      tag: 1,
      authCode: 2,
      flags: 0,
      path: [9, 8],
    );
    expect(
      packet.payload,
      encodeTracePayload(tag: 1, authCode: 2, flags: 0, path: [9, 8]),
    );
  });
}

import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('encodes and decodes a framed payload', () {
    final codec = SerialFrameCodec();
    final frame = codec.encodeFrame([1, 2, 3]);
    expect(frame[0], frameOutboundPrefix);
    expect(frame[1], 3);
    expect(codec.ingest(frame), [
      [1, 2, 3],
    ]);
  });

  test('decodes frames split across chunks', () {
    final codec = SerialFrameCodec();
    final frame = codec.encodeFrame(List.generate(50, (i) => i));
    final a = codec.ingest(frame.sublist(0, 10));
    final b = codec.ingest(frame.sublist(10));
    expect(a, isEmpty);
    expect(b.length, 1);
    expect(b.single.length, 50);
  });

  test('skips junk bytes before a valid frame', () {
    final codec = SerialFrameCodec();
    final frame = codec.encodeFrame([0xAA, 0xBB]);
    final frames = codec.ingest([0x00, 0x11, 0x22, ...frame]);
    expect(frames.length, 1);
    expect(frames.single, [0xAA, 0xBB]);
  });

  test('rejects oversized payloads and recovers', () {
    final codec = SerialFrameCodec();
    // Header claiming 200 bytes (over the 169 payload cap) is skipped.
    final bad = Uint8List.fromList([frameInboundPrefix, 200, 0, 1, 2, 3]);
    final good = codec.encodeFrame([7]);
    final frames = codec.ingest([...bad, ...good]);
    expect(frames.length, 1);
    expect(frames.single, [7]);
  });

  test('accepts multiple frames in one chunk', () {
    final codec = SerialFrameCodec();
    final data = <int>[
      ...codec.encodeFrame([1]),
      ...codec.encodeFrame([2, 3]),
    ];
    final frames = codec.ingest(data);
    expect(frames.length, 2);
    expect(frames[0], [1]);
    expect(frames[1], [2, 3]);
  });
}

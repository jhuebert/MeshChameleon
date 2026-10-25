import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

Uint8List _encode(List<int> payload, {int prefix = frameOutboundPrefix}) =>
    SerialFrameCodec.bidirectional().encodeFrame(payload, prefix: prefix);

void main() {
  test('encodes and decodes a framed payload', () {
    final codec = SerialFrameCodec(direction: FrameDirection.outbound);
    final frame = codec.encodeFrame([1, 2, 3]);
    expect(frame[0], frameOutboundPrefix);
    expect(frame[1], 3);
    expect(codec.ingest(frame), [
      [1, 2, 3],
    ]);
  });

  test('encodes with an explicit inbound prefix for device-facing clients', () {
    final codec = SerialFrameCodec(direction: FrameDirection.inbound);
    final frame = codec.encodeFrame([1, 2, 3], prefix: frameInboundPrefix);
    expect(frame[0], frameInboundPrefix);
    expect(frame[1], 3);
    expect(codec.ingest(frame), [
      [1, 2, 3],
    ]);
  });

  test('codec_accepts_169_172_176_payload_rejects_177', () {
    expect(maxCompanionPayloadSize, 176);
    expect(serialHeaderSize, 3);
    expect(maxSerialFrameSize, 179);

    final codec = SerialFrameCodec(direction: FrameDirection.outbound);
    for (final length in [169, 172, 176]) {
      final payload = List<int>.generate(length, (i) => i & 0xFF);
      final frame = codec.encodeFrame(payload);
      expect(frame.length, length + serialHeaderSize,
          reason: '$length-byte payload + 3-byte header');
      expect(codec.ingest(frame).single, payload);
    }

    expect(
      () => codec.encodeFrame(List.filled(177, 0)),
      throwsArgumentError,
      reason: 'the payload cap excludes the TCP header',
    );
  });

  test('codec_handles_fragmented_and_concatenated_max_frames', () {
    final codec = SerialFrameCodec(direction: FrameDirection.inbound);
    final first = List<int>.generate(176, (i) => i & 0xFF);
    final second = List<int>.filled(176, 0x11);
    final firstFrame = _encode(first, prefix: frameInboundPrefix);
    final secondFrame = _encode(second, prefix: frameInboundPrefix);

    // Split every part of the 3-byte header, then the payload.
    expect(codec.ingest(firstFrame.sublist(0, 1)), isEmpty);
    expect(codec.ingest(firstFrame.sublist(1, 2)), isEmpty);
    expect(codec.ingest(firstFrame.sublist(2, 3)), isEmpty);
    expect(codec.ingest(firstFrame.sublist(3, 100)), isEmpty);
    final completed = codec.ingest(firstFrame.sublist(100));
    expect(completed.single, first);

    // Concatenated maximum frames with junk before them.
    final concatenated =
        codec.ingest([0x00, 0xFF, ...firstFrame, ...secondFrame]);
    expect(concatenated.length, 2);
    expect(concatenated[0], first);
    expect(concatenated[1], second);

    // An oversize frame (177 payload bytes) is skipped and the next valid
    // frame still decodes.
    final oversize = Uint8List.fromList([
      frameInboundPrefix,
      177,
      0,
      ...List<int>.filled(177, 0),
    ]);
    final recovered = codec.ingest([...oversize, ...secondFrame]);
    expect(recovered.single, second);
  });

  test('server_rejects_outbound_prefix_as_command', () {
    final server = SerialFrameCodec(direction: FrameDirection.inbound);
    expect(
      server.ingest(_encode([cmdDeviceQuery], prefix: frameOutboundPrefix)),
      isEmpty,
    );
    expect(
      server
          .ingest(_encode([cmdDeviceQuery], prefix: frameInboundPrefix))
          .single,
      [cmdDeviceQuery],
    );
  });

  test('device_rejects_inbound_prefix', () {
    final device = SerialFrameCodec(direction: FrameDirection.outbound);
    expect(
      device.ingest(_encode([respCodeDeviceInfo], prefix: frameInboundPrefix)),
      isEmpty,
    );
    expect(
      device
          .ingest(_encode([respCodeDeviceInfo], prefix: frameOutboundPrefix))
          .single,
      [respCodeDeviceInfo],
    );
  });

  test('ble_raw_limit_excludes_tcp_header', () {
    // BLE carries a raw 176-byte payload; the 3-byte TCP header is not part of
    // the limit, so 177 raw bytes (which would fit 179 framed) are rejected.
    expect(decodeBleFrame(List.filled(176, 0x5A))!.length, 176);
    expect(decodeBleFrame(List.filled(177, 0x5A)), isNull);
    expect(decodeBleFrame(List.filled(179, 0x5A)), isNull);
  });

  test('decodes frames split across chunks', () {
    final codec = SerialFrameCodec(direction: FrameDirection.outbound);
    final frame = codec.encodeFrame(List.generate(50, (i) => i));
    final a = codec.ingest(frame.sublist(0, 10));
    final b = codec.ingest(frame.sublist(10));
    expect(a, isEmpty);
    expect(b.length, 1);
    expect(b.single.length, 50);
  });

  test('skips junk bytes before a valid frame', () {
    final codec = SerialFrameCodec(direction: FrameDirection.outbound);
    final frame = codec.encodeFrame([0xAA, 0xBB]);
    final frames = codec.ingest([0x00, 0x11, 0x22, ...frame]);
    expect(frames.length, 1);
    expect(frames.single, [0xAA, 0xBB]);
  });

  test('rejects oversized payloads and recovers', () {
    final codec = SerialFrameCodec(direction: FrameDirection.inbound);
    // Header claiming 177 bytes (over the 176-byte payload cap) is skipped.
    final bad = Uint8List.fromList([frameInboundPrefix, 177, 0, 1, 2, 3]);
    final good = _encode([7], prefix: frameInboundPrefix);
    final frames = codec.ingest([...bad, ...good]);
    expect(frames.length, 1);
    expect(frames.single, [7]);
  });

  test('accepts multiple frames in one chunk', () {
    final codec = SerialFrameCodec(direction: FrameDirection.outbound);
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

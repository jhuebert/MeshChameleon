import 'dart:typed_data';

import 'constants.dart';

/// The direction a frame is expected to travel.
enum FrameDirection { inbound, outbound }

/// USB-serial / TCP frame codec for the MeshCore companion protocol.
///
/// Frames are `prefix(1) | length(2, LE) | payload`. Inbound frames use `'<'`
/// (0x3C); outbound frames use `'>'` (0x3E). [direction] makes the codec reject
/// the other endpoint's prefix; only development clients that both send and
/// receive frames use [SerialFrameCodec.bidirectional]. Adapted from
/// `meshcore-open` (`usb_serial_frame_codec.dart`, MIT).
class SerialFrameCodec {
  /// Accept only frames travelling in [direction].
  SerialFrameCodec({
    required this.direction,
    this.maxPayloadLength = maxCompanionPayloadSize,
  });

  /// Accept either delimiter. Intended for test/development clients that send
  /// `'<'` frames and receive `'>'` frames on the same socket.
  SerialFrameCodec.bidirectional({
    this.maxPayloadLength = maxCompanionPayloadSize,
  }) : direction = null;

  final FrameDirection? direction;
  final int maxPayloadLength;
  final List<int> _buffer = <int>[];
  int _startIndex = 0;

  bool _acceptsPrefix(int prefix) => switch (direction) {
        FrameDirection.inbound => prefix == frameInboundPrefix,
        FrameDirection.outbound => prefix == frameOutboundPrefix,
        null => prefix == frameInboundPrefix || prefix == frameOutboundPrefix,
      };

  void reset() {
    _buffer.clear();
    _startIndex = 0;
  }

  /// Wrap a payload in a frame.
  ///
  /// [prefix] defaults to the outbound (`'>'`) delimiter used when the radio
  /// replies to the app. A device-facing client (the proxy talking to a stock
  /// companion) must use the inbound `'<'` prefix instead.
  Uint8List encodeFrame(
    List<int> payload, {
    int prefix = frameOutboundPrefix,
  }) {
    if (payload.length > maxPayloadLength) {
      throw ArgumentError.value(
        payload.length,
        'payload.length',
        'payload exceeds $maxPayloadLength bytes',
      );
    }
    final out = Uint8List(3 + payload.length);
    out[0] = prefix;
    out[1] = payload.length & 0xFF;
    out[2] = (payload.length >> 8) & 0xFF;
    out.setRange(3, out.length, payload);
    return out;
  }

  /// Feed bytes and return any complete frames in the accepted direction. Junk
  /// bytes, including the other endpoint's prefix, are skipped. Payloads longer
  /// than [maxPayloadLength] are treated as junk.
  List<Uint8List> ingest(List<int> bytes) {
    if (bytes.isEmpty) return const <Uint8List>[];
    _buffer.addAll(bytes);
    final frames = <Uint8List>[];
    while (true) {
      if (_startIndex >= _buffer.length) {
        _buffer.clear();
        _startIndex = 0;
        return frames;
      }
      final first = _buffer[_startIndex];
      if (!_acceptsPrefix(first)) {
        _startIndex++;
        _compact();
        continue;
      }
      final available = _buffer.length - _startIndex;
      if (available < 3) {
        _compact(force: true);
        return frames;
      }
      final payloadLength = _buffer[_startIndex + 1] | (_buffer[_startIndex + 2] << 8);
      if (payloadLength > maxPayloadLength) {
        _startIndex++;
        _compact();
        continue;
      }
      final frameLength = 3 + payloadLength;
      if (available < frameLength) {
        _compact(force: true);
        return frames;
      }
      frames.add(
        Uint8List.fromList(
          _buffer.sublist(_startIndex + 3, _startIndex + frameLength),
        ),
      );
      _startIndex += frameLength;
      _compact();
    }
  }

  void _compact({bool force = false}) {
    if (_startIndex == 0) return;
    if (!force && _startIndex < 1024 && _startIndex < (_buffer.length ~/ 2)) {
      return;
    }
    _buffer.removeRange(0, _startIndex);
    _startIndex = 0;
  }
}

/// Validate a raw single frame (BLE NUS uses one GATT write/notify per
/// companion payload). BLE carries no serial header, so the limit is the full
/// [maxCompanionPayloadSize], not the framed TCP size.
Uint8List? decodeBleFrame(List<int> bytes) {
  if (bytes.isEmpty) return null;
  if (bytes.length > maxCompanionPayloadSize) return null;
  return Uint8List.fromList(bytes);
}

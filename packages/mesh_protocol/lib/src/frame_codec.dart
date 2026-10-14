import 'dart:typed_data';

import 'constants.dart';

/// USB-serial / TCP frame codec for the MeshCore companion protocol.
///
/// Frames are `prefix(1) | length(2, LE) | payload`. Inbound frames use `'<'`
/// (0x3C); outbound frames use `'>'` (0x3E). Adapted from `meshcore-open`
/// (`usb_serial_frame_codec.dart`, MIT).
class SerialFrameCodec {
  SerialFrameCodec({this.maxPayloadLength = maxPayloadSize});

  final int maxPayloadLength;
  final List<int> _buffer = <int>[];
  int _startIndex = 0;

  void reset() {
    _buffer.clear();
    _startIndex = 0;
  }

  /// Wrap a payload in an outbound (`'>'`) frame.
  Uint8List encodeFrame(List<int> payload) {
    if (payload.length > maxPayloadLength) {
      throw ArgumentError.value(
        payload.length,
        'payload.length',
        'payload exceeds $maxPayloadLength bytes',
      );
    }
    final out = Uint8List(3 + payload.length);
    out[0] = frameOutboundPrefix;
    out[1] = payload.length & 0xFF;
    out[2] = (payload.length >> 8) & 0xFF;
    out.setRange(3, out.length, payload);
    return out;
  }

  /// Feed bytes and return any complete inbound frames. Junk bytes before a
  /// valid `'<'`/`'>'` prefix are skipped. Payloads longer than
  /// [maxPayloadLength] are treated as junk.
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
      if (first != frameInboundPrefix && first != frameOutboundPrefix) {
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

/// Decode a raw single frame (BLE NUS uses one GATT write per frame).
Uint8List? decodeBleFrame(List<int> bytes) {
  if (bytes.isEmpty) return null;
  final payloadLength = bytes.length;
  if (payloadLength > maxPayloadSize) return null;
  return Uint8List.fromList(bytes);
}

import 'dart:convert';
import 'dart:typed_data';

/// Sequential little-endian binary reader with pointer tracking.
///
/// Adapted from `meshcore-open` (`meshcore_protocol.dart`, MIT).
class BufferReader {
  BufferReader(Uint8List data) : _buffer = Uint8List.fromList(data);

  final Uint8List _buffer;
  int _pointer = 0;
  int _lastPointer = 0;

  int get position => _pointer;
  int get remaining => _buffer.length - _pointer;

  int readByte() => readBytes(1)[0];

  Uint8List readBytes(int count) {
    _lastPointer = _pointer;
    if (count < 0 || _pointer + count > _buffer.length) {
      throw RangeError(
        'Attempted to read $count bytes at offset $_pointer, but only '
        '$remaining bytes remaining in buffer of length ${_buffer.length}',
      );
    }
    final data = _buffer.sublist(_pointer, _pointer + count);
    _pointer += count;
    return data;
  }

  void skipBytes(int count) {
    _lastPointer = _pointer;
    if (count < 0 || _pointer + count > _buffer.length) {
      throw RangeError('Attempted to skip $count bytes at offset $_pointer');
    }
    _pointer += count;
  }

  Uint8List readRemainingBytes() => readBytes(remaining);

  int readUInt8() => readBytes(1)[0];

  int readInt8() {
    final b = readByte();
    return b >= 0x80 ? b - 0x100 : b;
  }

  int readUInt16Le() {
    final b = readBytes(2);
    return b[0] | (b[1] << 8);
  }

  int readUInt32Le() {
    final b = readBytes(4);
    return (b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)) & 0xFFFFFFFF;
  }

  int readInt32Le() {
    final v = readUInt32Le();
    return v >= 0x80000000 ? v - 0x100000000 : v;
  }

  void rewind() => _pointer = _lastPointer;

  /// Read a NUL-terminated UTF-8 string, consuming up to [maxLength] bytes.
  String readCString({int maxLength = -1}) {
    final maxLen = maxLength >= 0 ? maxLength : remaining;
    final value = <int>[];
    var counter = 0;
    while (counter < maxLen) {
      final byte = readByte();
      if (byte == 0) break;
      value.add(byte);
      counter++;
    }
    return _tryUtf8(value);
  }
}

/// Accumulating binary writer with little-endian helpers.
class BufferWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  int get length => _builder.length;
  Uint8List toBytes() => _builder.toBytes();

  void writeByte(int byte) => _builder.addByte(byte & 0xFF);
  void writeBytes(List<int> bytes) => _builder.add(bytes);

  void writeUInt16Le(int num) {
    final bytes = Uint8List(2)
      ..buffer.asByteData().setUint16(0, num & 0xFFFF, Endian.little);
    writeBytes(bytes);
  }

  void writeUInt32Le(int num) {
    final bytes = Uint8List(4)
      ..buffer.asByteData().setUint32(0, num & 0xFFFFFFFF, Endian.little);
    writeBytes(bytes);
  }

  void writeInt32Le(int num) {
    final bytes = Uint8List(4)
      ..buffer.asByteData().setInt32(0, num, Endian.little);
    writeBytes(bytes);
  }

  void writeString(String string) =>
      writeBytes(utf8.encode(string));

  /// Write a UTF-8 string into exactly [maxLength] bytes, NUL padded.
  void writeCString(String string, int maxLength) {
    final bytes = Uint8List(maxLength);
    final encoded = utf8.encode(string);
    final limit = encoded.length < maxLength ? encoded.length : maxLength;
    for (var i = 0; i < limit; i++) {
      bytes[i] = encoded[i];
    }
    writeBytes(bytes);
  }

  /// Write [bytes] into exactly [totalLength] bytes, zero padded/truncated.
  void writeBytesPadded(List<int> bytes, int totalLength) {
    final padded = Uint8List(totalLength);
    final limit = bytes.length < totalLength ? bytes.length : totalLength;
    for (var i = 0; i < limit; i++) {
      padded[i] = bytes[i];
    }
    writeBytes(padded);
  }
}

String _tryUtf8(List<int> value) {
  try {
    return utf8.decode(value, allowMalformed: true);
  } catch (_) {
    return String.fromCharCodes(value);
  }
}

/// Convert a lowercase/uppercase hex string to bytes.
Uint8List hexToBytes(String hex) {
  if (hex.isEmpty || hex.length.isOdd) {
    throw FormatException('Invalid hex string length: ${hex.length}');
  }
  final result = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < result.length; i++) {
    result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}

String bytesToHex(List<int> bytes) =>
    bytes.map((b) => (b & 0xFF).toRadixString(16).padLeft(2, '0')).join();

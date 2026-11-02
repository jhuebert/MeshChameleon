import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('BufferReader', () {
    test('tracks position and remaining', () {
      final r = BufferReader(Uint8List.fromList([1, 2, 3, 4]));
      expect(r.position, 0);
      expect(r.remaining, 4);
      r.skipBytes(2);
      expect(r.position, 2);
      expect(r.remaining, 2);
      expect(r.readRemainingBytes(), [3, 4]);
      expect(r.remaining, 0);
    });

    test('reads signed values from two bytes complement encodings', () {
      final r = BufferReader(Uint8List.fromList([0xFF]));
      expect(r.readInt8(), -1);

      final int16 = BufferReader(Uint8List.fromList([0xFE, 0xFF]));
      expect(int16.readInt16Le(), -2);

      final int32 = BufferReader(Uint8List.fromList([0xFE, 0xFF, 0xFF, 0xFF]));
      expect(int32.readInt32Le(), -2);
    });

    test('reads unsigned values across the sign boundary', () {
      final r = BufferReader(Uint8List.fromList([
        0xFF, 0xFF, 0xFF, 0xFF, // uint32 max
        0x00, 0x80, // 0x8000
        0xFE, 0x7F, // 0x7FFE
      ]));
      expect(r.readUInt32Le(), 0xFFFFFFFF);
      expect(r.readUInt16Le(), 0x8000);
      expect(r.readInt16Le(), 0x7FFE);
    });

    test('rejects negative and overlong reads', () {
      final r = BufferReader(Uint8List.fromList([1, 2]));
      expect(() => r.readBytes(-1), throwsRangeError);
      expect(() => r.readBytes(3), throwsRangeError);
      expect(() => r.skipBytes(-1), throwsRangeError);
      expect(() => r.skipBytes(3), throwsRangeError);
      expect(r.position, 0, reason: 'a failed read must not advance');
    });

    test('readCString stops at NUL and honours maxLength', () {
      final r = BufferReader(Uint8List.fromList([0x68, 0x69, 0, 9, 9]));
      expect(r.readCString(), 'hi');
      expect(r.position, 3);

      final capped = BufferReader(Uint8List.fromList([0x61, 0x62, 0x63]));
      expect(capped.readCString(maxLength: 2), 'ab');
      expect(capped.position, 2);
    });

    test('readCString decodes malformed UTF-8 lossily', () {
      final r = BufferReader(Uint8List.fromList([0xFF, 0x41, 0]));
      expect(r.readCString(), contains('A'));
    });

    test('readCString without a terminator reads to the end', () {
      final r = BufferReader(Uint8List.fromList([0x68, 0x69]));
      expect(r.readCString(), 'hi');
      expect(r.remaining, 0);
    });
  });

  group('BufferWriter', () {
    test('writes big-endian values and masked bytes', () {
      final w = BufferWriter()
        ..writeUInt16Be(0x1234)
        ..writeByte(0x1FF)
        ..writeUInt16Le(0x10001);
      expect(w.toBytes(), [0x12, 0x34, 0xFF, 0x01, 0x00]);
    });

    test('writeBytesPadded pads, truncates, and reports length', () {
      final w = BufferWriter()..writeBytesPadded([1, 2, 3], 5);
      expect(w.length, 5);
      expect(w.toBytes(), [1, 2, 3, 0, 0]);

      final truncated = BufferWriter()..writeBytesPadded([1, 2, 3, 4], 2);
      expect(truncated.toBytes(), [1, 2]);

      final empty = BufferWriter()..writeBytesPadded(const [], 3);
      expect(empty.toBytes(), [0, 0, 0]);
    });

    test('writeCString truncates to the fixed field width', () {
      final w = BufferWriter()..writeCString('abcdef', 3);
      expect(w.toBytes(), [0x61, 0x62, 0x63]);
    });

    test('writeString emits UTF-8 bytes', () {
      final w = BufferWriter()..writeString('café');
      expect(w.toBytes(), [0x63, 0x61, 0x66, 0xC3, 0xA9]);
    });
  });

  group('byte helpers', () {
    test('bytesEqual compares contents, not identity', () {
      expect(bytesEqual([1, 2, 3], [1, 2, 3]), isTrue);
      expect(bytesEqual([1, 2], [1, 2, 3]), isFalse);
      expect(bytesEqual([1, 2, 3], [1, 9, 3]), isFalse);
      expect(bytesEqual(const [], const []), isTrue);
    });

    test('hexToBytes rejects empty and odd-length input', () {
      expect(() => hexToBytes(''), throwsFormatException);
      expect(() => hexToBytes('abc'), throwsFormatException);
    });

    test('hexToBytes rejects non-hex digits', () {
      expect(() => hexToBytes('zz'), throwsFormatException);
    });

    test('hexToBytes accepts mixed case and bytesToHex masks', () {
      expect(hexToBytes('AaFf'), [0xAA, 0xFF]);
      expect(bytesToHex([0x100, -1, 0]), '00ff00');
    });
  });
}

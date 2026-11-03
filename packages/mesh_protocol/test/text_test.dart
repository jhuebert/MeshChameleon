import 'dart:convert';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('validateAdvertName', () {
    test('accepts normal names including multi-byte UTF-8', () {
      expect(validateAdvertName('node'), 'node');
      expect(validateAdvertName('café'), 'café');
      expect(validateAdvertName('a' * 31), 'a' * 31);
    });

    test('rejects empty and overlong names', () {
      expect(validateAdvertName(''), isNull);
      expect(validateAdvertName('a' * 32), isNull);
      // 16 two-byte runes are 32 bytes even though there are 16 characters.
      expect(validateAdvertName('é' * 16), isNull);
      expect(validateAdvertName('é' * 15), 'é' * 15);
    });

    test('rejects embedded NUL and control characters', () {
      expect(validateAdvertName('a\u0000b'), isNull);
      expect(validateAdvertName('line\nbreak'), isNull);
      expect(validateAdvertName('tab\there'), isNull);
      expect(validateAdvertName('del\u007f'), isNull);
      expect(validateAdvertName('c1\u009f'), isNull);
      // A printable rune just outside the control ranges is fine.
      expect(validateAdvertName('nbsp\u00a0'), 'nbsp\u00a0');
    });
  });

  group('decodeAdvertNameBytes', () {
    test('accepts one trailing NUL and trims it', () {
      expect(decodeAdvertNameBytes(utf8.encode('node')), 'node');
      expect(decodeAdvertNameBytes([...utf8.encode('node'), 0]), 'node');
    });

    test('rejects empty, overlong, and embedded NUL input', () {
      expect(decodeAdvertNameBytes(const []), isNull);
      expect(decodeAdvertNameBytes([0]), isNull);
      expect(decodeAdvertNameBytes(List.filled(32, 0x61)), isNull);
      expect(decodeAdvertNameBytes([0x61, 0, 0x62, 0]), isNull);
    });

    test('rejects malformed UTF-8 and control characters', () {
      expect(decodeAdvertNameBytes([0xFF]), isNull);
      expect(decodeAdvertNameBytes([0x61, 0x0A]), isNull);
    });
  });

  group('decodeContactNameBytes', () {
    test('ignores padding after the first NUL', () {
      final raw = [...utf8.encode('peer'), 0, 0xFF, 0xFF];
      expect(decodeContactNameBytes(raw), 'peer');
    });

    test('accepts an empty fixed field', () {
      expect(decodeContactNameBytes(const []), '');
      expect(decodeContactNameBytes([0, 1, 2]), '');
    });

    test('accepts a name with no NUL terminator', () {
      expect(decodeContactNameBytes(utf8.encode('peer')), 'peer');
    });

    test('rejects overlong, malformed, and control input', () {
      expect(decodeContactNameBytes(List.filled(32, 0x61)), isNull);
      expect(decodeContactNameBytes([0xFF]), isNull);
      expect(decodeContactNameBytes([0x61, 0x00, 0x62]), 'a');
      expect(decodeContactNameBytes([0x0A]), isNull);
    });
  });

  group('isValidAdvertCoordinateMicros', () {
    test('accepts inclusive coordinate bounds', () {
      expect(isValidAdvertCoordinateMicros(0, 0), isTrue);
      expect(isValidAdvertCoordinateMicros(90000000, 180000000), isTrue);
      expect(isValidAdvertCoordinateMicros(-90000000, -180000000), isTrue);
    });

    test('rejects coordinates outside the bounds', () {
      expect(isValidAdvertCoordinateMicros(90000001, 0), isFalse);
      expect(isValidAdvertCoordinateMicros(-90000001, 0), isFalse);
      expect(isValidAdvertCoordinateMicros(0, 180000001), isFalse);
      expect(isValidAdvertCoordinateMicros(0, -180000001), isFalse);
    });
  });

  _truncateTests();
}

void _truncateTests() {
  group('utf8CutIndex', () {
    test('backs off a continuation byte', () {
      final bytes = utf8.encode('aé'); // [0x61, 0xC3, 0xA9]
      expect(utf8CutIndex(bytes, 2), 1);
      expect(utf8CutIndex(bytes, 3), 3);
      expect(utf8CutIndex(bytes, 99), 3);
      expect(utf8CutIndex(bytes, -1), 0);
    });
  });

  group('truncateUtf8Bytes', () {
    test('leaves a value that already fits unchanged', () {
      expect(truncateUtf8Bytes(utf8.encode('ok'), 10), utf8.encode('ok'));
    });

    test('appends the ellipsis within the byte limit', () {
      final result = truncateUtf8Bytes(utf8.encode('abcdef'), 5);
      expect(utf8.decode(result), 'ab...');
      expect(result, hasLength(5));
    });

    test('does not split a multi-byte code point', () {
      final result = truncateUtf8Bytes(utf8.encode('aaaaé'), 5);
      expect(utf8.decode(result), 'aa...');
    });

    test('handles limits at or below the ellipsis size', () {
      expect(truncateUtf8Bytes(utf8.encode('abcdef'), 0), isEmpty);
      expect(utf8.decode(truncateUtf8Bytes(utf8.encode('abcdef'), 2)), '..');
    });
  });
}

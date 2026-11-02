import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('hashing', () {
    test('sha256 and hmacSha256 produce 32-byte digests', () {
      expect(CryptoUtils.sha256([1, 2, 3]), hasLength(32));
      expect(CryptoUtils.hmacSha256([1, 2], [3, 4]), hasLength(32));
    });

    test('packetHash includes the TRACE path length only for traces', () {
      final traceShort = CryptoUtils.packetHash(payloadTypeTrace, 1, [9]);
      final traceLong = CryptoUtils.packetHash(payloadTypeTrace, 2, [9]);
      expect(traceShort, isNot(traceLong));

      final textShort = CryptoUtils.packetHash(payloadTypeTxtMsg, 1, [9]);
      final textLong = CryptoUtils.packetHash(payloadTypeTxtMsg, 2, [9]);
      expect(textShort, textLong);
    });

    test('packetCrc is an unsigned 32-bit value', () {
      expect(
        CryptoUtils.packetCrc(payloadTypeTxtMsg, 0, [1, 2, 3]),
        inInclusiveRange(0, 0xFFFFFFFF),
      );
    });
  });

  group('AES', () {
    test('encrypt/decrypt round trips an exact block', () {
      final key = Uint8List(16)..[0] = 1;
      final plain = Uint8List.fromList(List.generate(16, (i) => i));
      final cipher = CryptoUtils.aesEcbEncrypt(key, plain);
      expect(cipher, hasLength(16));
      expect(CryptoUtils.aesEcbDecrypt(key, cipher), plain);
    });

    test('macThenDecrypt rejects data with no ciphertext', () {
      expect(
        () => CryptoUtils.macThenDecrypt(
            Uint8List(16), Uint8List(32), Uint8List.fromList([1, 2])),
        throwsFormatException,
      );
    });
  });

  group('transportCode', () {
    test('is stable and never uses the reserved zero value', () {
      final key = Uint8List(16)..[0] = 7;
      final code = CryptoUtils.transportCode(key, payloadTypeAdvert, [1, 2]);
      expect(code, CryptoUtils.transportCode(key, payloadTypeAdvert, [1, 2]));
      expect(code, isNot(0));
      expect(code, isNot(0xFFFF));
    });
  });

  group('X25519 helpers', () {
    test('clampScalar rejects the wrong length and clamps the ends', () {
      expect(
        () => CryptoUtils.x25519ClampScalar(Uint8List(31)),
        throwsArgumentError,
      );
      final clamped = CryptoUtils.x25519ClampScalar(Uint8List(32));
      expect(clamped[0], 0);
      expect(clamped[31], 64);
    });

    test('ed25519PublicToX25519 rejects the wrong length', () {
      expect(
        () => CryptoUtils.ed25519PublicToX25519(Uint8List(31)),
        throwsArgumentError,
      );
    });

    test('expandSeed rejects the wrong length', () {
      expect(
        () => CryptoUtils.ed25519ExpandSeedToMeshcore64(Uint8List(31)),
        throwsArgumentError,
      );
    });

    test('publicFromScalar rejects the wrong length', () {
      expect(
        () => CryptoUtils.ed25519PublicFromScalar(Uint8List(31)),
        throwsArgumentError,
      );
    });

    test('signFromExpanded rejects the wrong key length', () {
      expect(
        () => CryptoUtils.ed25519SignFromExpanded(Uint8List(63), [1]),
        throwsArgumentError,
      );
    });

    test('shared secret is symmetric for derived X25519 keys', () async {
      final alice = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 5);
      final bob = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 6);
      final a = await CryptoUtils.x25519SharedSecret(
          alice.x25519Private, bob.publicKey);
      final b = await CryptoUtils.x25519SharedSecret(
          bob.x25519Private, alice.publicKey);
      expect(a, b);
      expect(a, hasLength(32));
    });
  });

  group('base64ToBytes', () {
    test('decodes a valid PSK and rejects invalid input', () {
      expect(CryptoUtils.base64ToBytes('AQID'), [1, 2, 3]);
      expect(() => CryptoUtils.base64ToBytes('!!!'), throwsFormatException);
    });
  });
}

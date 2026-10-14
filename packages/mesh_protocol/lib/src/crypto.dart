import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart' as c;
import 'package:pointycastle/export.dart' as pc;

import 'constants.dart';

final BigInt _p25519 = (BigInt.one << 255) - BigInt.from(19);

/// Low-level MeshCore crypto primitives.
///
/// MeshCore uses AES-128 in ECB mode with a 2-byte HMAC-SHA256 tag, plus
/// Ed25519 signatures and Ed25519-derived X25519 ECDH.
class CryptoUtils {
  const CryptoUtils._();

  static Uint8List sha256(List<int> data) =>
      Uint8List.fromList(crypto.sha256.convert(data).bytes);

  static Uint8List hmacSha256(List<int> key, List<int> data) =>
      Uint8List.fromList(crypto.Hmac(crypto.sha256, key).convert(data).bytes);

  /// AES-128 ECB encrypt, zero-padding to a 16-byte boundary.
  static Uint8List aesEcbEncrypt(List<int> key, List<int> data) {
    final cipher = pc.ECBBlockCipher(pc.AESEngine())
      ..init(true, pc.KeyParameter(Uint8List.fromList(key)));
    final padLen = (cipherBlockSize - (data.length % cipherBlockSize)) % cipherBlockSize;
    final padded = Uint8List.fromList([...data, ...List<int>.filled(padLen, 0)]);
    final out = Uint8List(padded.length);
    for (var i = 0; i < padded.length; i += cipherBlockSize) {
      cipher.processBlock(padded, i, out, i);
    }
    return out;
  }

  /// AES-128 ECB decrypt, returning the first [ciphertext.length] bytes.
  static Uint8List aesEcbDecrypt(List<int> key, List<int> ciphertext) {
    final cipher = pc.ECBBlockCipher(pc.AESEngine())
      ..init(false, pc.KeyParameter(Uint8List.fromList(key)));
    final origLen = ciphertext.length;
    final padLen = (cipherBlockSize - (origLen % cipherBlockSize)) % cipherBlockSize;
    final padded = Uint8List.fromList([...ciphertext, ...List<int>.filled(padLen, 0)]);
    final out = Uint8List(padded.length);
    for (var i = 0; i < padded.length; i += cipherBlockSize) {
      cipher.processBlock(padded, i, out, i);
    }
    return Uint8List.sublistView(out, 0, origLen);
  }

  /// `mac(2) || AES-ECB(plaintext)`.
  static Uint8List encryptThenMac(
    List<int> aesKey,
    List<int> sharedSecret,
    List<int> plaintext,
  ) {
    final ciphertext = aesEcbEncrypt(aesKey, plaintext);
    final mac = hmacSha256(sharedSecret, ciphertext).sublist(0, cipherMacSize);
    return Uint8List.fromList([...mac, ...ciphertext]);
  }

  /// Verify the 2-byte HMAC and AES-ECB decrypt.
  ///
  /// Throws [FormatException] on a bad MAC.
  static Uint8List macThenDecrypt(
    List<int> aesKey,
    List<int> sharedSecret,
    List<int> data,
  ) {
    if (data.length <= cipherMacSize) {
      throw const FormatException('data too short to contain MAC + ciphertext');
    }
    final mac = data.sublist(0, cipherMacSize);
    final ciphertext = data.sublist(cipherMacSize);
    final expected = hmacSha256(sharedSecret, ciphertext).sublist(0, cipherMacSize);
    var diff = 0;
    for (var i = 0; i < cipherMacSize; i++) {
      diff |= mac[i] ^ expected[i];
    }
    if (diff != 0) {
      throw const FormatException('invalid HMAC');
    }
    return aesEcbDecrypt(aesKey, ciphertext);
  }

  /// SHA-256 packet hash (includes payload type, and path_len for TRACE).
  static Uint8List packetHash(int payloadType, int pathLen, List<int> payload) {
    final sha = crypto.sha256.convert([
      payloadType,
      if (payloadType == payloadTypeTrace) ...[
        pathLen & 0xFF,
        (pathLen >> 8) & 0xFF,
      ],
      ...payload,
    ]);
    return Uint8List.fromList(sha.bytes);
  }

  /// 32-bit CRC derived from the packet hash (little-endian, unsigned).
  static int packetCrc(int payloadType, int pathLen, List<int> payload) {
    final hash = packetHash(payloadType, pathLen, payload);
    return (hash[0] | (hash[1] << 8) | (hash[2] << 16) | (hash[3] << 24)) &
        0xFFFFFFFF;
  }

  /// Clamp a 32-byte scalar for X25519 (matches `key_exchange.c`).
  static Uint8List x25519ClampScalar(List<int> scalar) {
    if (scalar.length != 32) {
      throw ArgumentError('scalar must be 32 bytes');
    }
    final s = Uint8List.fromList(scalar);
    s[0] &= 248;
    s[31] &= 63;
    s[31] |= 64;
    return s;
  }

  /// Convert an Ed25519 public key to its X25519 (Montgomery) equivalent.
  ///
  /// Only the Edwards y-coordinate is needed: `u = (1 + y) / (1 - y) mod p`.
  static Uint8List ed25519PublicToX25519(List<int> edPublicKey) {
    if (edPublicKey.length != 32) {
      throw ArgumentError('ed25519 public key must be 32 bytes');
    }
    // y is the low 255 bits, little-endian; the top bit is the x sign.
    final bytes = Uint8List.fromList(edPublicKey)..[31] &= 0x7F;
    var y = BigInt.zero;
    for (var i = 31; i >= 0; i--) {
      y = (y << 8) | BigInt.from(bytes[i]);
    }
    final numerator = (BigInt.one + y) % _p25519;
    final denominator = (BigInt.one - y) % _p25519;
    final u = (numerator * denominator.modInverse(_p25519)) % _p25519;
    return _bigIntTo32Le(u);
  }

  /// Expand a 32-byte Ed25519 seed to the 64-byte MeshCore key form.
  static Uint8List ed25519ExpandSeedToMeshcore64(List<int> seed) {
    if (seed.length != 32) {
      throw ArgumentError('seed must be 32 bytes');
    }
    final h = Uint8List.fromList(crypto.sha512.convert(seed).bytes);
    return Uint8List.fromList([
      ...x25519ClampScalar(h.sublist(0, 32)),
      ...h.sublist(32, 64),
    ]);
  }

  /// X25519 public key derived from a (clamped) private scalar.
  static Future<Uint8List> x25519PublicFromPrivate(List<int> privateScalar) async {
    final keyPair =
        await c.X25519().newKeyPairFromSeed(Uint8List.fromList(privateScalar));
    return Uint8List.fromList(
      (await keyPair.extractPublicKey()).bytes,
    );
  }

  /// X25519 ECDH shared secret with a peer Ed25519 public key.
  static Future<Uint8List> x25519SharedSecret(
    List<int> privateScalar,
    List<int> peerEd25519Public,
  ) async {
    final peerX = ed25519PublicToX25519(peerEd25519Public);
    final keyPair =
        await c.X25519().newKeyPairFromSeed(Uint8List.fromList(privateScalar));
    final shared = await c.X25519().sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: c.SimplePublicKey(peerX, type: c.KeyPairType.x25519),
    );
    return Uint8List.fromList(await shared.extractBytes());
  }

  /// Derive the Ed25519 public key from a 32-byte scalar (no clamping).
  ///
  /// Used to reproduce the firmware's `ed25519_derive_pub()` for the 64-byte
  /// MeshCore key form, where only the scalar (not the seed) is available.
  static Uint8List ed25519PublicFromScalar(List<int> scalar) {
    if (scalar.length != 32) {
      throw ArgumentError('scalar must be 32 bytes');
    }
    var s = BigInt.zero;
    for (var i = 31; i >= 0; i--) {
      s = (s << 8) | BigInt.from(scalar[i] & 0xFF);
    }
    final point = _edwardsScalarMultBase(s);
    return _encodeEdwardsPoint(point);
  }

  static final BigInt _edwardsBaseX = BigInt.parse(
    '15112221349535400772501151409588531511454012693041857206046113283949847762202',
  );
  static final BigInt _edwardsBaseY = BigInt.parse(
    '46316835694926478169428394003475163141307993866256225615783033603165251855960',
  );

  /// Scalar multiplication of the Ed25519 base point using extended coordinates.
  static List<BigInt> _edwardsScalarMultBase(BigInt scalar) {
    var result = [BigInt.zero, BigInt.one, BigInt.one, BigInt.zero]; // identity
    var addend = [
      _edwardsBaseX,
      _edwardsBaseY,
      BigInt.one,
      (_edwardsBaseX * _edwardsBaseY) % _p25519,
    ];
    var k = scalar;
    while (k > BigInt.zero) {
      if (k.isOdd) {
        result = _edwardsAdd(result, addend);
      }
      addend = _edwardsAdd(addend, addend);
      k = k >> 1;
    }
    return result;
  }

  static List<BigInt> _edwardsAdd(List<BigInt> p1, List<BigInt> p2) {
    final x1 = p1[0], y1 = p1[1], z1 = p1[2], t1 = p1[3];
    final x2 = p2[0], y2 = p2[1], z2 = p2[2], t2 = p2[3];
    final a = _mod((y1 - x1) * (y2 - x2));
    final b = _mod((y1 + x1) * (y2 + x2));
    final c = _mod(t1 * BigInt.two * _d25519 * t2);
    final d = _mod(z1 * BigInt.two * z2);
    final e = b - a;
    final f = d - c;
    final g = d + c;
    final h = b + a;
    return [_mod(e * f), _mod(g * h), _mod(f * g), _mod(e * h)];
  }

  static Uint8List _encodeEdwardsPoint(List<BigInt> point) {
    final zInv = point[2].modInverse(_p25519);
    final x = _mod(point[0] * zInv);
    final y = _mod(point[1] * zInv);
    final out = _bigIntTo32Le(y);
    out[31] |= (x.isOdd ? 1 : 0) << 7;
    return out;
  }

  static BigInt _mod(BigInt a) => ((a % _p25519) + _p25519) % _p25519;

  static BigInt get _d25519 => (BigInt.from(-121665) *
          BigInt.from(121666).modInverse(_p25519)) %
      _p25519;

  static Uint8List _bigIntTo32Le(BigInt value) {
    final out = Uint8List(32);
    var v = value;
    for (var i = 0; i < 32; i++) {
      out[i] = (v & BigInt.from(0xFF)).toInt();
      v = v >> 8;
    }
    return out;
  }

  // Retained for callers that need the raw curve constants.
  static BigInt get fieldPrime => _p25519;
  static BigInt get edwardsD => _d25519;

  /// Base64 decode helper for channel PSKs.
  static Uint8List base64ToBytes(String value) =>
      Uint8List.fromList(base64.decode(value));
}

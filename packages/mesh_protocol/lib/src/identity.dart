import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart' as c;

import 'constants.dart';
import 'crypto.dart';

/// The local MeshCore identity (Ed25519 + derived X25519 for ECDH).
///
/// Two key forms are supported:
///  * a 32-byte Ed25519 seed (fresh identities and seed imports);
///  * the 64-byte MeshCore firmware form `[scalar(32)][prefix(32)]`.
///
/// Both forms can sign: the 64-byte form is the expanded Ed25519 key, which is
/// all that is needed for RFC 8032 signing (see
/// [CryptoUtils.ed25519SignFromExpanded]). This is also the form the device
/// returns from `CMD_EXPORT_PRIVATE_KEY`.
class LocalIdentity {
  LocalIdentity._({
    required this.publicKey,
    required Uint8List? seed,
    required Uint8List? firmwareKey,
  })  : _seed = seed,
        _firmwareKey = firmwareKey;

  final Uint8List publicKey;
  final Uint8List? _seed;
  final Uint8List? _firmwareKey;
  c.SimpleKeyPair? _keyPair;
  Uint8List? _x25519Private;

  /// Whether this identity can produce Ed25519 signatures.
  ///
  /// Both the seed form and the 64-byte expanded form can sign.
  bool get canSign => _seed != null || _firmwareKey != null;

  /// 1-byte identity hash (first byte of the public key).
  int get hashByte => publicKey[0];

  Uint8List get publicKeyPrefix6 => Uint8List.sublistView(publicKey, 0, 6);

  /// X25519 private scalar (clamped) for ECDH.
  Uint8List get x25519Private {
    final cached = _x25519Private;
    if (cached != null) return cached;
    return _x25519Private = _seed != null
        ? _clampFromSeed(_seed)
        : CryptoUtils.x25519ClampScalar(_firmwareKey!.sublist(0, 32));
  }

  static Uint8List _clampFromSeed(Uint8List seed) {
    final digest = Uint8List.fromList(crypto.sha512.convert(seed).bytes);
    return CryptoUtils.x25519ClampScalar(digest.sublist(0, 32));
  }

  /// Generate a fresh random identity from 32 bytes of entropy.
  ///
  /// Retry the rare public-key prefix `00`/`FF` so a freshly generated identity
  /// also passes the firmware's import validation.
  static Future<LocalIdentity> generate([Random? random]) async {
    final rng = random ?? Random.secure();
    while (true) {
      final seed = Uint8List.fromList(
        List<int>.generate(32, (_) => rng.nextInt(256)),
      );
      final identity = await fromSeed(seed);
      if (identity.publicKey[0] != 0x00 &&
          identity.publicKey[0] != 0xFF) {
        return identity;
      }
    }
  }

  /// Create an identity from a 32-byte Ed25519 seed.
  static Future<LocalIdentity> fromSeed(Uint8List seed) async {
    if (seed.length != 32) {
      throw ArgumentError('seed must be 32 bytes');
    }
    final keyPair = await c.Ed25519().newKeyPairFromSeed(seed);
    final pub = await keyPair.extractPublicKey();
    final identity = LocalIdentity._(
      publicKey: Uint8List.fromList(pub.bytes),
      seed: Uint8List.fromList(seed),
      firmwareKey: null,
    );
    identity._keyPair = keyPair;
    identity._x25519Private = _clampFromSeed(seed);
    return identity;
  }

  /// Firmware's known-good test client keypair, used by
  /// `LocalIdentity::validatePrivateKey` (`Identity.cpp:67-109`).
  static const _validationTestPrivate = <int>[
    0x70, 0x65, 0xE1, 0x8F, 0xD9, 0xFA, 0xBB, 0x70, //
    0xC1, 0xED, 0x90, 0xDC, 0xA1, 0x99, 0x07, 0xDE,
    0x69, 0x8C, 0x88, 0xB7, 0x09, 0xEA, 0x14, 0x6E,
    0xAF, 0xD9, 0x3D, 0x9B, 0x83, 0x0C, 0x7B, 0x60,
    0xC4, 0x68, 0x11, 0x93, 0xC7, 0x9B, 0xBC, 0x39,
    0x94, 0x5B, 0xA8, 0x06, 0x41, 0x04, 0xBB, 0x61,
    0x8F, 0x8F, 0xD7, 0xA8, 0x4A, 0x0A, 0xF6, 0xF5,
    0x70, 0x33, 0xD6, 0xE8, 0xDD, 0xCD, 0x64, 0x71,
  ];
  static const _validationTestPublic = <int>[
    0x1E, 0xC7, 0x71, 0x75, 0xB0, 0x91, 0x8E, 0xD2, //
    0x06, 0xF9, 0xAE, 0x04, 0xEC, 0x13, 0x6D, 0x6D,
    0x5D, 0x43, 0x15, 0xBB, 0x26, 0x30, 0x54, 0x27,
    0xF6, 0x45, 0xB4, 0x92, 0xE9, 0x35, 0x0C, 0x10,
  ];

  /// Complete firmware private-key validation for the 64-byte form.
  ///
  /// Reproduces `LocalIdentity::validatePrivateKey`: derive the public key
  /// from the supplied scalar, reject `00`/`FF` prefixes, and require a
  /// symmetric, non-zero ECDH exchange with the upstream test keypair. This is
  /// deliberately not a length check or scalar clamp.
  static Future<bool> validateMeshcore64(Uint8List key) async {
    if (key.length != 64) return false;
    try {
      final publicKey =
          CryptoUtils.ed25519PublicFromScalar(key.sublist(0, 32));
      if (publicKey[0] == 0x00 || publicKey[0] == 0xFF) return false;

      final testPrivate = Uint8List.fromList(_validationTestPrivate);
      final testPublic = Uint8List.fromList(_validationTestPublic);
      final ss1 = await CryptoUtils.x25519SharedSecret(
        key.sublist(0, 32),
        testPublic,
      );
      final ss2 = await CryptoUtils.x25519SharedSecret(
        testPrivate.sublist(0, 32),
        publicKey,
      );
      var diff = 0;
      for (var i = 0; i < 32; i++) {
        diff |= ss1[i] ^ ss2[i];
      }
      if (diff != 0) return false;
      var nonzero = 0;
      for (final byte in ss1) {
        nonzero |= byte;
      }
      return nonzero != 0;
    } catch (_) {
      return false;
    }
  }

  /// Firmware-name alias for [validateMeshcore64].
  static Future<bool> validatePrivateKey(Uint8List key) =>
      validateMeshcore64(key);

  /// Create an identity from the 64-byte MeshCore firmware key form.
  ///
  /// The public key is derived from the scalar; signing uses the expanded key
  /// directly (no seed recovery needed).
  static Future<LocalIdentity> fromMeshcore64(Uint8List key) async {
    if (key.length != 64) {
      throw ArgumentError('MeshCore key must be 64 bytes');
    }
    final scalar = CryptoUtils.x25519ClampScalar(key.sublist(0, 32));
    final pub = CryptoUtils.ed25519PublicFromScalar(key.sublist(0, 32));
    final identity = LocalIdentity._(
      publicKey: pub,
      seed: null,
      firmwareKey: Uint8List.fromList(key),
    );
    identity._x25519Private = scalar;
    return identity;
  }

  /// Import a 32-byte seed or 64-byte MeshCore key.
  static Future<LocalIdentity> import(Uint8List key) {
    if (key.length == 32) return fromSeed(key);
    if (key.length == 64) return fromMeshcore64(key);
    throw ArgumentError('key must be 32 or 64 bytes, got ${key.length}');
  }

  /// The 64-byte MeshCore storage/export form.
  Uint8List get meshcore64 {
    if (_firmwareKey != null) return Uint8List.fromList(_firmwareKey);
    return CryptoUtils.ed25519ExpandSeedToMeshcore64(_seed!);
  }

  /// Sign [message] with Ed25519.
  ///
  /// Seed identities use the `cryptography` signer; 64-byte identities sign
  /// directly from the expanded key. Both produce deterministic RFC 8032
  /// signatures.
  Future<Uint8List> sign(Uint8List message) async {
    final firmwareKey = _firmwareKey;
    if (firmwareKey != null) {
      return CryptoUtils.ed25519SignFromExpanded(firmwareKey, message);
    }
    final keyPair = _keyPair;
    if (keyPair == null) {
      throw UnsupportedError('identity has no signing key');
    }
    final signature = await c.Ed25519().sign(message, keyPair: keyPair);
    return Uint8List.fromList(signature.bytes);
  }

  /// Verify a signature from a peer identity.
  static Future<bool> verify(
    Uint8List message,
    Uint8List signature,
    Uint8List publicKey,
  ) async {
    try {
      return await c.Ed25519().verify(
        message,
        signature: c.Signature(
          signature,
          publicKey: c.SimplePublicKey(publicKey, type: c.KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  /// ECDH shared secret with a peer Ed25519 public key.
  Future<Uint8List> sharedSecret(Uint8List peerEd25519Public) =>
      CryptoUtils.x25519SharedSecret(x25519Private, peerEd25519Public);

  /// The X25519 public key (for peers that need it).
  Future<Uint8List> x25519Public() =>
      CryptoUtils.x25519PublicFromPrivate(x25519Private);

  /// The initial MeshCore default public channel secret.
  static Uint8List get defaultPublicChannelSecret =>
      CryptoUtils.base64ToBytes(publicGroupPsk);
}

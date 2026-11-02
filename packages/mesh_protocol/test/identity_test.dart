import 'dart:math';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('LocalIdentity.fromSeed', () {
    test('rejects a seed that is not 32 bytes', () {
      expect(
        () => LocalIdentity.fromSeed(Uint8List(31)),
        throwsArgumentError,
      );
      expect(
        () => LocalIdentity.fromSeed(Uint8List(33)),
        throwsArgumentError,
      );
    });

    test('reports canSign and caches the X25519 private scalar', () async {
      final identity = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 3);
      expect(identity.canSign, isTrue);
      final first = identity.x25519Private;
      final second = identity.x25519Private;
      expect(second, same(first));
      expect(first, hasLength(32));
      // Clamped X25519 scalars are divisible by the cofactor and have the
      // high bit pattern required by RFC 7748.
      expect(first[0] & 0x07, 0);
      expect(first[31] & 0xC0, 0x40);
    });

    test('meshcore64 is deterministic and round-trips through import',
        () async {
      final seed = Uint8List.fromList(List.generate(32, (i) => i * 3));
      final identity = await LocalIdentity.fromSeed(seed);
      expect(
          identity.meshcore64, CryptoUtils.ed25519ExpandSeedToMeshcore64(seed));
      final imported = await LocalIdentity.import(identity.meshcore64);
      expect(imported.publicKey, identity.publicKey);
      expect(imported.meshcore64, identity.meshcore64);
    });
  });

  group('LocalIdentity.generate', () {
    test('creates a usable signing identity', () async {
      final identity = await LocalIdentity.generate();
      expect(identity.canSign, isTrue);
      expect(identity.publicKey, hasLength(32));
      expect(identity.publicKey[0], isNot(0x00));
      expect(identity.publicKey[0], isNot(0xFF));
      expect(identity.meshcore64, hasLength(64));
    });

    test('accepts a deterministic Random source', () async {
      final a = await LocalIdentity.generate(Random(7));
      final b = await LocalIdentity.generate(Random(7));
      expect(a.publicKey, b.publicKey);
    });

    test('draws one 32-byte seed from the supplied Random', () async {
      final rng = _ScriptedRandom([0, 1, 2]);
      final identity = await LocalIdentity.generate(rng);
      expect(identity.canSign, isTrue);
      expect(rng.calls, greaterThanOrEqualTo(32));
    });
  });

  group('LocalIdentity.fromMeshcore64 and import', () {
    test('rejects a key that is not 64 bytes', () {
      expect(
        () => LocalIdentity.fromMeshcore64(Uint8List(63)),
        throwsArgumentError,
      );
    });

    test('import rejects unsupported key lengths', () {
      expect(
        () => LocalIdentity.import(Uint8List(16)),
        throwsArgumentError,
      );
      expect(
        () => LocalIdentity.import(Uint8List(65)),
        throwsArgumentError,
      );
    });

    test('import accepts both seed and expanded forms', () async {
      final seed = Uint8List(32)..[0] = 11;
      final seeded = await LocalIdentity.fromSeed(seed);
      final fromSeed = await LocalIdentity.import(seed);
      expect(fromSeed.publicKey, seeded.publicKey);

      final fromExpanded = await LocalIdentity.import(seeded.meshcore64);
      expect(fromExpanded.publicKey, seeded.publicKey);
    });

    test('meshcore64 returns a copy for expanded identities', () async {
      final seeded = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 12);
      final expanded = await LocalIdentity.fromMeshcore64(seeded.meshcore64);
      final a = expanded.meshcore64;
      final b = expanded.meshcore64;
      expect(a, b);
      expect(a, isNot(same(b)));
      a[0] ^= 0xFF;
      expect(expanded.meshcore64, b);
    });

    test('x25519 private scalar is the clamped first key half', () async {
      final seeded = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 13);
      final expanded = await LocalIdentity.fromMeshcore64(seeded.meshcore64);
      expect(
        expanded.x25519Private,
        CryptoUtils.x25519ClampScalar(seeded.meshcore64.sublist(0, 32)),
      );
    });
  });

  group('verification', () {
    test('rejects malformed signatures and public keys', () async {
      final identity = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 4);
      final message = Uint8List.fromList([1, 2, 3]);
      final signature = await identity.sign(message);

      expect(
        await LocalIdentity.verify(
            message, signature.sublist(0, 16), identity.publicKey),
        isFalse,
      );
      expect(
        await LocalIdentity.verify(message, signature, Uint8List(16)),
        isFalse,
      );
    });
  });

  group('default public channel secret', () {
    test('decodes the firmware PSK', () {
      final secret = LocalIdentity.defaultPublicChannelSecret;
      expect(secret, hasLength(16));
      expect(secret, CryptoUtils.base64ToBytes(publicGroupPsk));
    });
  });
}

/// Returns the scripted seeds one byte at a time and then repeats the last one.
class _ScriptedRandom implements Random {
  _ScriptedRandom(this._seeds);

  final List<int> _seeds;
  int calls = 0;

  @override
  int nextInt(int max) {
    calls++;
    final seedIndex = (calls - 1) ~/ 32;
    final index = seedIndex < _seeds.length ? seedIndex : _seeds.length - 1;
    return (_seeds[index] + (calls % 2)) % max;
  }

  @override
  double nextDouble() => 0;

  @override
  bool nextBool() => false;
}

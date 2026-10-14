import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('BufferReader/Writer', () {
    test('round trips little-endian integers and cstrings', () {
      final w = BufferWriter()
        ..writeByte(0xAB)
        ..writeUInt16Le(0x1234)
        ..writeUInt32Le(0xDEADBEEF)
        ..writeInt32Le(-12345)
        ..writeCString('hi', 8);
      final r = BufferReader(w.toBytes());
      expect(r.readByte(), 0xAB);
      expect(r.readUInt16Le(), 0x1234);
      expect(r.readUInt32Le(), 0xDEADBEEF);
      expect(r.readInt32Le(), -12345);
      expect(r.readCString(maxLength: 8), 'hi');
    });

    test('hex helpers round trip', () {
      expect(bytesToHex(hexToBytes('00ff10')), '00ff10');
    });
  });

  group('loraTimeOnAirMicros', () {
    test('grows with payload size and is positive', () {
      final small = loraTimeOnAirMicros(
        payloadBytes: 16,
        spreadingFactor: 10,
        bandwidthHz: 250000,
        codingRate: 5,
      );
      final large = loraTimeOnAirMicros(
        payloadBytes: 200,
        spreadingFactor: 10,
        bandwidthHz: 250000,
        codingRate: 5,
      );
      expect(small, greaterThan(0));
      expect(large, greaterThan(small));
    });

    test('low-data-rate optimisation applies to slow long symbols', () {
      // SF12 / BW125 => Tsym = 32.768 ms (> 16 ms), so DE is enabled.
      final airtime = loraTimeOnAirMicros(
        payloadBytes: 32,
        spreadingFactor: 12,
        bandwidthHz: 125000,
        codingRate: 8,
      );
      expect(airtime, greaterThan(0));
    });
  });

  group('PathUtils', () {
    test('1-byte hashes encode as hop count', () {
      expect(PathUtils.encodePathLen(1, 3), 3);
      expect(PathUtils.getHashSize(3), 1);
      expect(PathUtils.getHashCount(3), 3);
      expect(PathUtils.getByteLength(3), 3);
    });

    test('2- and 3-byte hashes pack size in high bits', () {
      expect(PathUtils.encodePathLen(2, 4), (1 << 6) | 4);
      expect(PathUtils.getHashSize((1 << 6) | 4), 2);
      expect(PathUtils.getByteLength((1 << 6) | 4), 8);
      expect(PathUtils.getHashSize((2 << 6) | 2), 3);
    });

    test('rejects oversized paths', () {
      expect(PathUtils.isValidPathLen(0), isTrue);
      expect(PathUtils.isValidPathLen(64), isTrue); // 64 one-byte hops
      expect(PathUtils.isValidPathLen((3 << 6) | 1), isFalse); // hash size 4
    });
  });

  group('Packet', () {
    test('write/read round trip for flood advert', () {
      final p = Packet()
        ..header = Packet.createHeader(payloadTypeAdvert, routeTypeFlood)
        ..payload = Uint8List.fromList([1, 2, 3, 4]);
      final bytes = p.writeTo();
      final parsed = Packet.readFrom(bytes);
      expect(parsed, isNotNull);
      expect(parsed!.payloadType, payloadTypeAdvert);
      expect(parsed.routeType, routeTypeFlood);
      expect(parsed.payload, [1, 2, 3, 4]);
    });

    test('round trip with transport codes and path', () {
      final p = Packet()
        ..header = Packet.createHeader(payloadTypeTxtMsg, routeTypeTransportFlood)
        ..transportCode0 = 0x1122
        ..transportCode1 = 0x3344
        ..setPath([0xAA, 0xBB])
        ..payload = Uint8List.fromList([9, 9]);
      final parsed = Packet.readFrom(p.writeTo())!;
      expect(parsed.hasTransportCodes, isTrue);
      expect(parsed.transportCode0, 0x1122);
      expect(parsed.transportCode1, 0x3344);
      expect(parsed.path, [0xAA, 0xBB]);
      expect(parsed.payload, [9, 9]);
    });
  });

  group('CryptoUtils', () {
    test('AES-ECB encrypt/decrypt round trips with padding', () {
      final key = Uint8List.fromList(List.generate(16, (i) => i));
      final plaintext = Uint8List.fromList(List.generate(30, (i) => i * 3 % 256));
      final cipher = CryptoUtils.aesEcbEncrypt(key, plaintext);
      expect(cipher.length, 32); // padded to block boundary
      expect(CryptoUtils.aesEcbDecrypt(key, cipher).sublist(0, 30), plaintext);
    });

    test('encryptThenMac/macThenDecrypt round trip and MAC check', () {
      final aesKey = Uint8List(16)..[0] = 7;
      final secret = Uint8List.fromList(List.generate(32, (i) => i));
      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);
      final data = CryptoUtils.encryptThenMac(aesKey, secret, plaintext);
      expect(CryptoUtils.macThenDecrypt(aesKey, secret, data).sublist(0, 5),
          plaintext);
      data[0] ^= 0xFF;
      expect(
        () => CryptoUtils.macThenDecrypt(aesKey, secret, data),
        throwsFormatException,
      );
    });

    test('packet hash and CRC are stable', () {
      final payload = Uint8List.fromList([1, 2, 3]);
      final hash = CryptoUtils.packetHash(payloadTypeTxtMsg, 0, payload);
      expect(hash.length, 32);
      expect(CryptoUtils.packetCrc(payloadTypeTxtMsg, 0, payload),
          hash[0] | (hash[1] << 8) | (hash[2] << 16) | (hash[3] << 24));
    });
  });

  group('Identity', () {
    test('fromSeed is deterministic and signs/verifies', () async {
      final seed = Uint8List.fromList(List.generate(32, (i) => i));
      final a = await LocalIdentity.fromSeed(seed);
      final b = await LocalIdentity.fromSeed(seed);
      expect(a.publicKey, b.publicKey);
      final message = Uint8List.fromList([1, 2, 3]);
      final sig = await a.sign(message);
      expect(sig.length, 64);
      expect(await LocalIdentity.verify(message, sig, b.publicKey), isTrue);
      expect(await LocalIdentity.verify(Uint8List.fromList([9]), sig, b.publicKey),
          isFalse);
    });

    test('meshcore64 export re-derives the same public key', () async {
      final a = await LocalIdentity.fromSeed(
        Uint8List.fromList(List.generate(32, (i) => (i * 7) % 256)),
      );
      final reimported = await LocalIdentity.fromMeshcore64(a.meshcore64);
      expect(reimported.publicKey, a.publicKey);
    });

    test('ECDH shared secret is symmetric', () async {
      final alice = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 1);
      final bob = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 2);
      final s1 = await alice.sharedSecret(bob.publicKey);
      final s2 = await bob.sharedSecret(alice.publicKey);
      expect(s1, s2);
      expect(s1.length, 32);
    });
  });

  group('PacketBuilder', () {
    test('advert verifies with the signer public key', () async {
      final identity = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 42);
      final pkt = await PacketBuilder.createAdvert(
        identity: identity,
        name: 'ProxyNode',
        lat: 40.1,
        lon: -96.2,
      );
      expect(pkt.payloadType, payloadTypeAdvert);
      expect(await PacketBuilder.verifyAdvert(pkt.payload), isTrue);
      final data = PacketBuilder.decodeAdvertData(
        pkt.payload.sublist(pubKeySize + timestampSize + signatureSize),
      );
      expect(data.name, 'ProxyNode');
      expect(data.lat, closeTo(40.1, 1e-6));
      expect(data.lon, closeTo(-96.2, 1e-6));
    });

    test('direct text message decrypts on the peer', () async {
      final alice = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 10);
      final bob = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 20);
      final contact = Contact(publicKey: bob.publicKey, name: 'bob');
      final (pkt, ackCrc) = await PacketBuilder.createTextMessage(
        contact: contact,
        identity: alice,
        message: 'hello bob',
      );
      expect(pkt.payloadType, payloadTypeTxtMsg);
      expect(pkt.payload[0], bob.publicKey[0]);
      expect(pkt.payload[1], alice.publicKey[0]);

      // Bob decrypts using the same ECDH secret.
      final secret = await bob.sharedSecret(alice.publicKey);
      final decrypted = CryptoUtils.macThenDecrypt(
        secret.sublist(0, 16),
        secret,
        pkt.payload.sublist(2),
      );
      final r = BufferReader(decrypted)
        ..skipBytes(4) // timestamp
        ..skipBytes(1); // flags
      expect(r.readCString(), 'hello bob');
      expect(ackCrc, isNot(0));
    });

    test('createTrace appends the path to the payload, direct route', () {
      final pkt = PacketBuilder.createTrace(
        tag: 0x11223344,
        authCode: 0x55667788,
        flags: 1,
        path: [0xAA, 0xBB, 0xCC],
      );
      expect(pkt.payloadType, payloadTypeTrace);
      expect(pkt.routeType, routeTypeDirect);
      expect(pkt.pathLenByte, 0);
      expect(pkt.path, isEmpty);
      final r = BufferReader(pkt.payload);
      expect(r.readUInt32Le(), 0x11223344);
      expect(r.readUInt32Le(), 0x55667788);
      expect(r.readByte(), 1);
      expect(r.readBytes(3), [0xAA, 0xBB, 0xCC]);

      // Round-trips through the wire codec.
      final reparsed = Packet.readFrom(pkt.writeTo())!;
      expect(reparsed.payloadType, payloadTypeTrace);
      expect(reparsed.payload, pkt.payload);
    });
  });
}

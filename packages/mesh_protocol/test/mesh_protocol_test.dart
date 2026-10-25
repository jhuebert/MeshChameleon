import 'dart:convert';
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

  group('virtual DEVICE_INFO', () {
    test('advertised baseline is the T16 MeshCore 1.18 target', () {
      final active = buildVirtualDeviceInfo(clientRepeat: 1, pathHashMode: 2);
      expect(active.firmwareVerCode, targetFirmwareVerCode);
      expect(active.version, targetCompatibilityVersion);
      expect(active.manufacturer, virtualBoardName);
      expect(active.maxContacts, 350);
      expect(active.maxChannels, 40);
      expect(active.blePin, 0);
      expect(active.clientRepeat, 1);
      expect(active.pathHashMode, 2);

      final historical = buildVirtualDeviceInfo(targetBaseline: false);
      expect(historical.firmwareVerCode, defaultFirmwareVerCode);
      expect(historical.version, activeDeviceVersion);
      expect(utf8.encode(active.manufacturer).length, lessThanOrEqualTo(40));
      expect(utf8.encode(active.version).length, lessThanOrEqualTo(20));
    });
  });

  group('PacketBuilder group data', () {
    final channel = Channel(
      name: 'Public',
      secret: Uint8List.fromList(LocalIdentity.defaultPublicChannelSecret),
    );

    test('group_tx_and_channel_rx_limits_are_distinct', () {
      expect(maxGroupDataLength, 165);
      expect(maxChannelDataLength, 167);
      expect(maxCompanionPayloadSize, 176);
      expect(maxSerialFrameSize, 179);
    });

    test('rejects overlong data, reserved type, and invalid paths', () {
      expect(
        () => PacketBuilder.createGroupData(
          channel: channel,
          dataType: 0x1234,
          data: List<int>.filled(166, 1),
        ),
        throwsArgumentError,
      );
      expect(
        () => PacketBuilder.createGroupData(
          channel: channel,
          dataType: dataTypeReserved,
          data: const [1],
        ),
        throwsArgumentError,
      );
      expect(
        () => PacketBuilder.createGroupData(
          channel: channel,
          dataType: 0x1234,
          data: const [1],
          path: const [1, 2, 3],
          pathLenEncoded: 4,
        ),
        throwsArgumentError,
      );
      expect(
        () => PacketBuilder.createGroupData(
          channel: channel,
          dataType: 0x1234,
          data: const [1],
          path: const [1],
          pathLenEncoded: 0xFF,
        ),
        throwsArgumentError,
      );
    });

    test('zero-hop direct and flood are distinct routes', () {
      final direct = PacketBuilder.createGroupData(
        channel: channel,
        dataType: 0x1234,
        data: const [1],
        path: const [],
        pathLenEncoded: 0,
      );
      expect(direct.routeType, routeTypeDirect);
      expect(direct.pathLenByte, 0);
      expect(direct.path, isEmpty);

      final flood = PacketBuilder.createGroupData(
        channel: channel,
        dataType: 0x1234,
        data: const [1],
      );
      expect(flood.routeType, routeTypeFlood);
      expect(flood.pathLenByte, 0);
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

    test('applyFloodScope adds transport codes for a non-zero key', () {
      final key = Uint8List(16)..[0] = 5;
      final p = Packet()
        ..header = Packet.createHeader(payloadTypeAdvert, routeTypeFlood)
        ..setPath(const [])
        ..payload = Uint8List.fromList([9, 8, 7]);
      expect(p.hasTransportCodes, isFalse);
      p.applyFloodScope(key);
      expect(p.hasTransportCodes, isTrue);
      expect(p.routeType, routeTypeTransportFlood);
      expect(p.transportCode0,
          CryptoUtils.transportCode(key, payloadTypeAdvert, [9, 8, 7]));
      expect(p.transportCode1, 0);
      // Round trips through the wire codec with the codes intact.
      final parsed = Packet.readFrom(p.writeTo())!;
      expect(parsed.hasTransportCodes, isTrue);
      expect(parsed.transportCode0, p.transportCode0);
    });

    test('applyFloodScope ignores zero keys and direct packets', () {
      final zero = Uint8List(16);
      final flood = Packet()
        ..header = Packet.createHeader(payloadTypeAdvert, routeTypeFlood)
        ..setPath(const [])
        ..payload = Uint8List.fromList([1]);
      flood.applyFloodScope(zero);
      expect(flood.hasTransportCodes, isFalse);

      final direct = Packet()
        ..header = Packet.createHeader(payloadTypeAdvert, routeTypeDirect)
        ..setPath([0xAA])
        ..payload = Uint8List.fromList([1]);
      direct.applyFloodScope(Uint8List(16)..[0] = 1);
      expect(direct.hasTransportCodes, isFalse);
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

    test('64-byte import signs identically to the seed identity', () async {
      final seed =
          Uint8List.fromList(List.generate(32, (i) => (i * 11 + 3) % 256));
      final seedId = await LocalIdentity.fromSeed(seed);
      final imported = await LocalIdentity.fromMeshcore64(seedId.meshcore64);
      expect(imported.canSign, isTrue);

      final message = Uint8List.fromList([10, 20, 30, 40, 50]);
      final seedSig = await seedId.sign(message);
      final importedSig = await imported.sign(message);
      // Ed25519 (RFC 8032) is deterministic, so both forms must agree exactly.
      expect(importedSig, seedSig);
      expect(
        await LocalIdentity.verify(message, importedSig, imported.publicKey),
        isTrue,
      );
    });

    test('ed25519SignFromExpanded matches the seed-derived signature',
        () async {
      final seed = Uint8List.fromList(List.generate(32, (i) => (i * 5) % 256));
      final identity = await LocalIdentity.fromSeed(seed);
      final message = Uint8List.fromList([1, 3, 5, 7, 9]);
      final expected = await identity.sign(message);
      final expanded = CryptoUtils.ed25519ExpandSeedToMeshcore64(seed);
      expect(CryptoUtils.ed25519SignFromExpanded(expanded, message), expected);
    });

    test('validateMeshcore64 matches the firmware test keypair', () async {
      const testPrivate = <int>[
        0x70, 0x65, 0xE1, 0x8F, 0xD9, 0xFA, 0xBB, 0x70, //
        0xC1, 0xED, 0x90, 0xDC, 0xA1, 0x99, 0x07, 0xDE,
        0x69, 0x8C, 0x88, 0xB7, 0x09, 0xEA, 0x14, 0x6E,
        0xAF, 0xD9, 0x3D, 0x9B, 0x83, 0x0C, 0x7B, 0x60,
        0xC4, 0x68, 0x11, 0x93, 0xC7, 0x9B, 0xBC, 0x39,
        0x94, 0x5B, 0xA8, 0x06, 0x41, 0x04, 0xBB, 0x61,
        0x8F, 0x8F, 0xD7, 0xA8, 0x4A, 0x0A, 0xF6, 0xF5,
        0x70, 0x33, 0xD6, 0xE8, 0xDD, 0xCD, 0x64, 0x71,
      ];
      const testPublic = <int>[
        0x1E, 0xC7, 0x71, 0x75, 0xB0, 0x91, 0x8E, 0xD2, //
        0x06, 0xF9, 0xAE, 0x04, 0xEC, 0x13, 0x6D, 0x6D,
        0x5D, 0x43, 0x15, 0xBB, 0x26, 0x30, 0x54, 0x27,
        0xF6, 0x45, 0xB4, 0x92, 0xE9, 0x35, 0x0C, 0x10,
      ];
      final privateKey = Uint8List.fromList(testPrivate);
      final identity = await LocalIdentity.fromMeshcore64(privateKey);
      expect(identity.publicKey, testPublic);
      expect(await LocalIdentity.validateMeshcore64(privateKey), isTrue);

      final seeded = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 7);
      expect(await LocalIdentity.validateMeshcore64(seeded.meshcore64),
          isTrue);

      expect(await LocalIdentity.validateMeshcore64(Uint8List(32)), isFalse);
      expect(await LocalIdentity.validateMeshcore64(Uint8List(64)), isFalse);
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
        timestamp: 1700000000,
      );
      expect(pkt.payloadType, payloadTypeAdvert);
      expect(await PacketBuilder.verifyAdvert(pkt.payload), isTrue);
      expect(
        BufferReader(pkt.payload.sublist(pubKeySize)).readUInt32Le(),
        1700000000,
      );
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
        timestamp: 1700000000,
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
      final r = BufferReader(decrypted);
      expect(r.readUInt32Le(), 1700000000);
      r.skipBytes(1); // flags
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

    test('createRawCustom builds a direct raw packet with a path', () {
      final pkt = PacketBuilder.createRawCustom(
        [1, 2, 3, 4],
        path: [0xAA, 0xBB],
        encodedPathLen: 0x02,
      );
      expect(pkt.payloadType, payloadTypeRawCustom);
      expect(pkt.routeType, routeTypeDirect);
      expect(pkt.pathLenByte, 0x02);
      expect(pkt.path, [0xAA, 0xBB]);
      expect(pkt.payload, [1, 2, 3, 4]);

      // Round-trips through the wire codec.
      final reparsed = Packet.readFrom(pkt.writeTo())!;
      expect(reparsed.payloadType, payloadTypeRawCustom);
      expect(reparsed.path, [0xAA, 0xBB]);
      expect(reparsed.payload, [1, 2, 3, 4]);
    });
  });
}

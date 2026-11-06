import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  Future<LocalIdentity> makeIdentity([int seedByte = 1]) =>
      LocalIdentity.fromSeed(Uint8List(32)..[0] = seedByte);

  Contact contactFor(LocalIdentity identity, {int outPathLen = -1}) => Contact(
        publicKey: identity.publicKey,
        name: 'peer',
        outPathLen: outPathLen,
        outPath: outPathLen > 0
            ? List.filled(PathUtils.getByteLength(outPathLen), 0xAA)
            : const [],
      );

  group('encodeAdvertData', () {
    test('encodes name and location flags', () {
      final data = PacketBuilder.encodeAdvertData(
        name: 'peer',
        lat: 12.5,
        lon: -3.25,
      );
      expect(data[0], advTypeChat | advertFlagHasLocation | advertFlagHasName);
      final r = BufferReader(data)..skipBytes(1);
      expect(r.readInt32Le(), 12500000);
      expect(r.readInt32Le(), -3250000);
      expect(r.readCString(), 'peer');
    });

    test('encodes only a name when there is no location', () {
      final data = PacketBuilder.encodeAdvertData(name: 'peer');
      expect(data[0], advTypeChat | advertFlagHasName);
      expect(data.sublist(1), [0x70, 0x65, 0x65, 0x72]);
    });

    test('encodes only a location when the name is empty', () {
      final data = PacketBuilder.encodeAdvertData(name: '', lat: 1, lon: 2);
      expect(data[0], advTypeChat | advertFlagHasLocation);
      expect(data, hasLength(1 + 8));
    });

    test('truncates an overlong name to the advert data budget', () {
      final data = PacketBuilder.encodeAdvertData(
        name: 'x' * 200,
        lat: 1,
        lon: 2,
      );
      expect(data.length, 96);
      expect(data[0], advTypeChat | advertFlagHasLocation | advertFlagHasName);
    });
  });

  group('ACK packets', () {
    test('createAckPacket preserves every ack byte', () {
      final p = PacketBuilder.createAckPacket([1, 2, 3, 4, 5, 6]);
      expect(p.payloadType, payloadTypeAck);
      expect(p.routeType, routeTypeDirect);
      expect(p.payload, [1, 2, 3, 4, 5, 6]);
    });

    test('createMultiAck prefixes remaining count and ACK type', () {
      final p = PacketBuilder.createMultiAck([9, 8, 7, 6], 3);
      expect(p.payloadType, payloadTypeMultipart);
      expect(p.routeType, routeTypeDirect);
      expect(p.payload, [(3 << 4) | payloadTypeAck, 9, 8, 7, 6]);
    });

    test('createMultiAck masks the remaining count to four bits', () {
      final p = PacketBuilder.createMultiAck([1], 0x12);
      expect(p.payload[0], (0x02 << 4) | payloadTypeAck);
    });

    test('ackHash skips zero bytes in the text', () {
      final pubkey = Uint8List(32)..[0] = 5;
      final withZeros = PacketBuilder.ackHash(
        timestamp: 1,
        flagsByte: 2,
        text: [0x61, 0, 0x62],
        senderPubkey: pubkey,
      );
      final withoutZeros = PacketBuilder.ackHash(
        timestamp: 1,
        flagsByte: 2,
        text: [0x61, 0x62],
        senderPubkey: pubkey,
      );
      expect(withZeros, withoutZeros);
      expect(withZeros, hasLength(4));
    });

    test('computeAckCrc is the little-endian first hash word', () {
      final pubkey = Uint8List(32)..[0] = 5;
      final hash = PacketBuilder.ackHash(
        timestamp: 42,
        flagsByte: 8,
        text: 'hi'.codeUnits,
        senderPubkey: pubkey,
      );
      expect(
        PacketBuilder.computeAckCrc(
          timestamp: 42,
          flagsByte: 8,
          message: 'hi',
          selfPubkey: pubkey,
        ),
        hash[0] | (hash[1] << 8) | (hash[2] << 16) | (hash[3] << 24),
      );
    });
  });

  group('createPathReturn', () {
    test('encrypts the path and extra bytes for the source', () async {
      final alice = await makeIdentity(1);
      final bob = await makeIdentity(2);
      final secret = await alice.sharedSecret(bob.publicKey);
      final p = PacketBuilder.createPathReturn(
        destHashByte: bob.publicKey[0],
        srcHashByte: alice.publicKey[0],
        secret: secret,
        path: [0xAA, 0xBB],
        pathLenEncoded: 2,
        extraType: payloadTypeAck,
        extra: [1, 2, 3, 4],
      );
      expect(p.payloadType, payloadTypePath);
      expect(p.routeType, routeTypeFlood);
      expect(p.payload[0], bob.publicKey[0]);
      expect(p.payload[1], alice.publicKey[0]);

      final plain = CryptoUtils.macThenDecrypt(
        secret.sublist(0, 16),
        secret,
        p.payload.sublist(2),
      );
      final r = BufferReader(plain);
      expect(r.readByte(), 2);
      expect(r.readBytes(2), [0xAA, 0xBB]);
      expect(r.readByte(), payloadTypeAck);
      expect(r.readBytes(4), [1, 2, 3, 4]);
    });
  });

  group('createTextMessage', () {
    test('uses a direct route and contact path when learned', () async {
      final alice = await makeIdentity(1);
      final bob = await makeIdentity(2);
      final contact = contactFor(bob, outPathLen: 2);
      final (p, ackCrc) = await PacketBuilder.createTextMessage(
        contact: contact,
        identity: alice,
        message: 'hi',
        timestamp: 100,
      );
      expect(p.routeType, routeTypeDirect);
      expect(p.pathLenByte, 2);
      expect(p.path, [0xAA, 0xAA]);
      expect(ackCrc, isNot(0));
    });

    test('uses a zero-hop direct route for outPathLen 0', () async {
      final alice = await makeIdentity(1);
      final bob = await makeIdentity(2);
      final contact = contactFor(bob, outPathLen: 0);
      final (p, _) = await PacketBuilder.createTextMessage(
        contact: contact,
        identity: alice,
        message: 'hi',
        timestamp: 100,
      );
      expect(p.routeType, routeTypeDirect);
      expect(p.pathLenByte, 0);
      expect(p.path, isEmpty);
    });

    test('flags encode the text type and attempt', () async {
      final alice = await makeIdentity(1);
      final bob = await makeIdentity(2);
      final contact = contactFor(bob);
      final (p, _) = await PacketBuilder.createTextMessage(
        contact: contact,
        identity: alice,
        message: 'hi',
        txtType: txtTypeSigned,
        attempt: 2,
        timestamp: 100,
      );
      final secret = await bob.sharedSecret(alice.publicKey);
      final plain = CryptoUtils.macThenDecrypt(
        secret.sublist(0, 16),
        secret,
        p.payload.sublist(2),
      );
      final r = BufferReader(plain)..skipBytes(4);
      expect(r.readByte(), ((txtTypeSigned & 0x3F) << 2) | 2);
    });

    test('attempts beyond 3 append the extended attempt tail', () async {
      final alice = await makeIdentity(1);
      final bob = await makeIdentity(2);
      final contact = contactFor(bob);
      final (p, _) = await PacketBuilder.createTextMessage(
        contact: contact,
        identity: alice,
        message: 'hi',
        attempt: 5,
        timestamp: 100,
      );
      final secret = await bob.sharedSecret(alice.publicKey);
      final plain = CryptoUtils.macThenDecrypt(
        secret.sublist(0, 16),
        secret,
        p.payload.sublist(2),
      );
      final r = BufferReader(plain)..skipBytes(4);
      expect(r.readByte(), (txtTypePlain << 2) | 1);
      expect(r.readCString(), 'hi');
      expect(r.readByte(), 5);
    });
  });

  group('group messages', () {
    final channel = Channel(
      name: 'Public',
      secret: Uint8List.fromList(List.generate(32, (i) => i + 1)),
    );

    test('createGroupText is flooded and decrypts on the channel', () {
      final p = PacketBuilder.createGroupText(
        channel: channel,
        message: 'hello',
        senderName: 'alice',
        timestamp: 100,
      );
      expect(p.payloadType, payloadTypeGrpTxt);
      expect(p.routeType, routeTypeFlood);
      final secret = Uint8List(32);
      secret.setRange(0, channel.secret.length, channel.secret);
      final plain = CryptoUtils.macThenDecrypt(
        secret.sublist(0, 16),
        secret,
        p.payload.sublist(1),
      );
      final r = BufferReader(plain);
      expect(r.readUInt32Le(), 100);
      expect(r.readByte(), 0);
      expect(r.readCString(), 'alice: hello');
    });

    test('createGroupText truncates content to the firmware text limit', () {
      final p = PacketBuilder.createGroupText(
        channel: channel,
        message: 'x' * 500,
        senderName: 'alice',
        timestamp: 100,
      );
      final secret = Uint8List(32);
      secret.setRange(0, channel.secret.length, channel.secret);
      final plain = CryptoUtils.macThenDecrypt(
        secret.sublist(0, 16),
        secret,
        p.payload.sublist(1),
      );
      final r = BufferReader(plain)..skipBytes(5);
      final content = r.readCString();
      expect(content, hasLength(maxTextLength));
      expect(content, startsWith('alice: '));
    });

    test('createGroupData handles flood and zero-hop direct routes', () {
      final flood = PacketBuilder.createGroupData(
        channel: channel,
        dataType: 0x1234,
        data: [1, 2, 3],
      );
      expect(flood.routeType, routeTypeFlood);
      expect(flood.payloadType, payloadTypeGrpData);
      expect(flood.pathLenByte, 0);

      final direct = PacketBuilder.createGroupData(
        channel: channel,
        dataType: 0x1234,
        data: [1],
        path: const [],
        pathLenEncoded: 0,
      );
      expect(direct.routeType, routeTypeDirect);
      expect(direct.pathLenByte, 0);
    });

    test('createGroupData writes a multi-byte path', () {
      final p = PacketBuilder.createGroupData(
        channel: channel,
        dataType: 0x1234,
        data: [1],
        path: [0xAA, 0xBB],
        pathLenEncoded: 2,
      );
      expect(p.routeType, routeTypeDirect);
      expect(p.path, [0xAA, 0xBB]);
      expect(p.pathLenByte, 2);
    });

    test('createGroupData rejects a path length mismatch', () {
      expect(
        () => PacketBuilder.createGroupData(
          channel: channel,
          dataType: 0x1234,
          data: const [1],
          path: const [1],
          pathLenEncoded: 2,
        ),
        throwsArgumentError,
      );
    });
  });

  group('control, trace, and raw packets', () {
    test('createControlData is a zero-hop direct packet', () {
      final p = PacketBuilder.createControlData([0x80, 1, 2]);
      expect(p.payloadType, payloadTypeControl);
      expect(p.routeType, routeTypeDirect);
      expect(p.pathLenByte, 0);
      expect(p.payload, [0x80, 1, 2]);
    });

    test('createTrace masks flags and appends the path to the payload', () {
      final p = PacketBuilder.createTrace(
        tag: 1,
        authCode: 2,
        flags: 0x1FF,
        path: [3, 4],
      );
      expect(p.payload, [1, 0, 0, 0, 2, 0, 0, 0, 0xFF, 3, 4]);
    });

    test('createRawCustom encodes the path or defaults to a flood route', () {
      final direct = PacketBuilder.createRawCustom(
        [9],
        path: [0xAA],
        encodedPathLen: 1,
      );
      expect(direct.routeType, routeTypeDirect);
      expect(direct.pathLenByte, 1);

      final zeroHop = PacketBuilder.createRawCustom([9]);
      expect(zeroHop.pathLenByte, 0);
    });
  });

  group('protocol request and response', () {
    test('createProtocolRequest uses the contact route by default', () async {
      final alice = await makeIdentity(1);
      final bob = await makeIdentity(2);
      final p = await PacketBuilder.createProtocolRequest(
        contact: contactFor(bob, outPathLen: 1),
        identity: alice,
        protocolCode: reqTypeGetStatus,
        data: [7],
        timestamp: 100,
      );
      expect(p.payloadType, payloadTypeReq);
      expect(p.routeType, routeTypeDirect);
      expect(p.pathLenByte, 1);
    });

    test('createProtocolRequest honours an explicit flood override', () async {
      final alice = await makeIdentity(1);
      final bob = await makeIdentity(2);
      final p = await PacketBuilder.createProtocolRequest(
        contact: contactFor(bob, outPathLen: 1),
        identity: alice,
        protocolCode: reqTypeGetStatus,
        timestamp: 100,
        flood: true,
      );
      expect(p.routeType, routeTypeFlood);
      expect(p.path, isEmpty);
    });

    test('createProtocolRequest floods when the route is unknown', () async {
      final alice = await makeIdentity(1);
      final bob = await makeIdentity(2);
      final p = await PacketBuilder.createProtocolRequest(
        contact: contactFor(bob),
        identity: alice,
        protocolCode: reqTypeGetStatus,
        timestamp: 100,
      );
      expect(p.routeType, routeTypeFlood);
    });

    test('createProtocolResponse follows the contact route or override',
        () async {
      final alice = await makeIdentity(1);
      final bob = await makeIdentity(2);
      final direct = await PacketBuilder.createProtocolResponse(
        contact: contactFor(bob, outPathLen: 1),
        identity: alice,
        data: [1, 2],
      );
      expect(direct.payloadType, payloadTypeResponse);
      expect(direct.routeType, routeTypeDirect);
      expect(direct.pathLenByte, 1);

      final flood = await PacketBuilder.createProtocolResponse(
        contact: contactFor(bob, outPathLen: 1),
        identity: alice,
        data: [1, 2],
        flood: true,
      );
      expect(flood.routeType, routeTypeFlood);
      expect(flood.path, isEmpty);
    });

    test('createAnonRequest embeds the full sender public key', () async {
      final alice = await makeIdentity(1);
      final bob = await makeIdentity(2);
      final p = await PacketBuilder.createAnonRequest(
        contact: contactFor(bob),
        identity: alice,
        data: [9, 8],
        timestamp: 100,
      );
      expect(p.payloadType, payloadTypeAnonReq);
      expect(p.routeType, routeTypeFlood);
      expect(p.payload[0], bob.publicKey[0]);
      expect(p.payload.sublist(1, 1 + pubKeySize), alice.publicKey);
    });

    test('createAnonRequest uses a learned direct route', () async {
      final alice = await makeIdentity(1);
      final bob = await makeIdentity(2);
      final p = await PacketBuilder.createAnonRequest(
        contact: contactFor(bob, outPathLen: 2),
        identity: alice,
        data: [9, 8],
        timestamp: 100,
      );
      expect(p.routeType, routeTypeDirect);
      expect(p.pathLenByte, 2);
    });
  });

  group('advert verification and decoding', () {
    test('verifyAdvert rejects a short payload', () async {
      expect(await PacketBuilder.verifyAdvert(Uint8List(10)), isFalse);
    });

    test('verifyAdvert rejects a tampered signature', () async {
      final identity = await makeIdentity(1);
      final p = await PacketBuilder.createAdvert(
        identity: identity,
        name: 'peer',
        timestamp: 100,
      );
      final tampered = Uint8List.fromList(p.payload);
      tampered[pubKeySize + timestampSize] ^= 0xFF;
      expect(await PacketBuilder.verifyAdvert(tampered), isFalse);
    });

    test('decodeAdvertData returns invalid for empty input', () {
      final data = PacketBuilder.decodeAdvertData(const []);
      expect(data.valid, isFalse);
      expect(data.name, '');
    });

    test('decodeAdvertData rejects a truncated location', () {
      final data = PacketBuilder.decodeAdvertData([
        advTypeChat | advertFlagHasLocation,
        0,
        0,
      ]);
      expect(data.valid, isFalse);
      expect(data.hasLocation, isFalse);
    });

    test('decodeAdvertData skips declared feature words', () {
      final appdata = [
        advTypeChat |
            advertFlagFeature1 |
            advertFlagFeature2 |
            advertFlagHasName,
        1,
        2,
        3,
        4,
        ...'peer'.codeUnits,
      ];
      final data = PacketBuilder.decodeAdvertData(appdata);
      expect(data.valid, isTrue);
      expect(data.name, 'peer');
      expect(data.hasName, isTrue);
      expect(data.hasLocation, isFalse);
    });

    test('decodeAdvertData rejects truncated feature words', () {
      expect(
        PacketBuilder.decodeAdvertData([advertFlagFeature1, 1]).valid,
        isFalse,
      );
      expect(
        PacketBuilder.decodeAdvertData([advertFlagFeature2, 1]).valid,
        isFalse,
      );
    });

    test('decodeAdvertData rejects a name flag with no name bytes', () {
      final data = PacketBuilder.decodeAdvertData([advertFlagHasName]);
      expect(data.valid, isFalse);
      expect(data.hasName, isFalse);
    });

    test('decodeAdvertData treats an empty name field as valid', () {
      final data = PacketBuilder.decodeAdvertData([
        advertFlagHasLocation | advertFlagHasName,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
      ]);
      expect(data.valid, isTrue);
      expect(data.hasName, isFalse);
      expect(data.hasLocation, isTrue);
      expect(data.lat, 0);
      expect(data.lon, 0);
    });

    test('decodeAdvertData stops the name at NUL padding', () {
      final data = PacketBuilder.decodeAdvertData([
        advertFlagHasName,
        ...'peer'.codeUnits,
        0,
        0,
      ]);
      expect(data.valid, isTrue);
      expect(data.name, 'peer');
    });

    test('decodeAdvertData rejects malformed UTF-8 names', () {
      final data = PacketBuilder.decodeAdvertData([advertFlagHasName, 0xFF]);
      expect(data.valid, isFalse);
    });

    test('decodeAdvertData decodes a full advert with location and name', () {
      final data = PacketBuilder.decodeAdvertData([
        advTypeRepeater | advertFlagHasLocation | advertFlagHasName,
        ...(BufferWriter()
              ..writeInt32Le(42123456)
              ..writeInt32Le(-87654321))
            .toBytes(),
        ...'node'.codeUnits,
      ]);
      expect(data.valid, isTrue);
      expect(data.flags,
          advTypeRepeater | advertFlagHasLocation | advertFlagHasName);
      expect(data.lat, closeTo(42.123456, 1e-9));
      expect(data.lon, closeTo(-87.654321, 1e-9));
      expect(data.name, 'node');
      expect(data.hasLocation, isTrue);
      expect(data.hasName, isTrue);
    });
  });
}

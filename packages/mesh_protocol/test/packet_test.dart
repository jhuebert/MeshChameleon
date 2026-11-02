import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  Packet packet({
    int payloadType = payloadTypeTxtMsg,
    int routeType = routeTypeDirect,
    List<int> path = const [],
    List<int> payload = const [1, 2, 3],
    int? encodedPathLen,
  }) {
    final p = Packet()
      ..header = Packet.createHeader(payloadType, routeType)
      ..payload = Uint8List.fromList(payload);
    p.setPath(path, encodedPathLen);
    return p;
  }

  test('header packs route, payload type, and version', () {
    final header = Packet.createHeader(payloadTypeAdvert, routeTypeDirect, 1);
    expect(header & phRouteMask, routeTypeDirect);
    expect((header >> phTypeShift) & phTypeMask, payloadTypeAdvert);
    expect((header >> phVerShift) & phVerMask, 1);
  });

  test('route predicates cover flood, transport, and direct routes', () {
    final flood = packet(routeType: routeTypeFlood);
    expect(flood.isRouteFlood, isTrue);
    expect(flood.isRouteDirect, isFalse);
    expect(flood.hasTransportCodes, isFalse);

    final transportFlood = packet(routeType: routeTypeTransportFlood);
    expect(transportFlood.isRouteFlood, isTrue);
    expect(transportFlood.isRouteDirect, isFalse);
    expect(transportFlood.hasTransportCodes, isTrue);

    final direct = packet(routeType: routeTypeDirect);
    expect(direct.isRouteFlood, isFalse);
    expect(direct.isRouteDirect, isTrue);
    expect(direct.hasTransportCodes, isFalse);

    final transportDirect = packet(routeType: routeTypeTransportDirect);
    expect(transportDirect.isRouteFlood, isFalse);
    expect(transportDirect.isRouteDirect, isTrue);
    expect(transportDirect.hasTransportCodes, isTrue);
  });

  test('path accessors decode the encoded length byte', () {
    final p = packet(path: [1, 2, 3, 4], encodedPathLen: (1 << 6) | 2);
    expect(p.pathHashSize, 2);
    expect(p.pathHashCount, 2);
    expect(p.pathByteLength, 4);
  });

  test('setPath defaults to one-byte hashes', () {
    final p = Packet()..setPath([1, 2, 3]);
    expect(p.pathLenByte, 3);
    expect(p.pathHashSize, 1);
    expect(p.pathHashCount, 3);
  });

  test('rawLength includes the header, path, transport codes, and payload', () {
    expect(packet(path: [1, 2], payload: [9, 9]).rawLength, 2 + 2 + 2);
    final scoped = packet(
      routeType: routeTypeTransportFlood,
      path: const [],
      payload: [9],
    );
    expect(scoped.rawLength, 2 + 4 + 1);
  });

  test('writeTo emits transport codes and writes only the declared path', () {
    final p = packet(
      routeType: routeTypeTransportDirect,
      path: [0xAA, 0xBB, 0xCC],
      encodedPathLen: 2,
      payload: [7, 8],
    )
      ..transportCode0 = 0x1234
      ..transportCode1 = 0xABCD;
    expect(p.writeTo(), [
      p.header,
      0x34,
      0x12,
      0xCD,
      0xAB,
      2,
      0xAA,
      0xBB,
      7,
      8,
    ]);
  });

  test('readFrom rejects empty, unsupported-version, and truncated packets',
      () {
    expect(Packet.readFrom(Uint8List(0)), isNull);

    // Version 2 sets the high version bit and is unsupported.
    expect(
      Packet.readFrom(Uint8List.fromList([
        Packet.createHeader(payloadTypeTxtMsg, routeTypeFlood, 2),
      ])),
      isNull,
    );

    // Transport-coded packet with fewer than four code bytes.
    final shortCodes = Packet.createHeader(
      payloadTypeTxtMsg,
      routeTypeTransportFlood,
    );
    expect(Packet.readFrom(Uint8List.fromList([shortCodes, 1, 2])), isNull);

    // No path length byte.
    expect(
        Packet.readFrom(Uint8List.fromList([shortCodes, 1, 2, 3, 4])), isNull);

    // Reserved hash width (path_len high bits 0b11).
    expect(
      Packet.readFrom(Uint8List.fromList([
        Packet.createHeader(payloadTypeTxtMsg, routeTypeDirect),
        0xC0,
      ])),
      isNull,
    );

    // Declared path bytes are missing.
    expect(
      Packet.readFrom(Uint8List.fromList([
        Packet.createHeader(payloadTypeTxtMsg, routeTypeDirect),
        2,
        0xAA,
      ])),
      isNull,
    );
  });

  test('readFrom parses a packet with an empty payload', () {
    final p = Packet.readFrom(Uint8List.fromList([
      Packet.createHeader(payloadTypeAdvert, routeTypeFlood),
      0,
    ]))!;
    expect(p.path, isEmpty);
    expect(p.payload, isEmpty);
  });

  test('calculatePacketHash is stable for the same bytes', () {
    final a = packet(payload: [1, 2, 3]);
    final b = packet(payload: [1, 2, 3]);
    expect(a.calculatePacketHash(), b.calculatePacketHash());
    expect(a.calculatePacketHash(), hasLength(32));
  });

  test('applyFloodScope ignores non-flood routes and short keys', () {
    final direct = packet(routeType: routeTypeDirect);
    direct.applyFloodScope(Uint8List(16)..[0] = 1);
    expect(direct.hasTransportCodes, isFalse);

    final flood = packet(routeType: routeTypeFlood);
    flood.applyFloodScope(Uint8List(15)..[0] = 1);
    expect(flood.hasTransportCodes, isFalse);
    flood.applyFloodScope(Uint8List(17)..[0] = 1);
    expect(flood.hasTransportCodes, isFalse);
  });
}

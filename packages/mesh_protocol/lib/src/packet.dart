import 'dart:typed_data';

import 'constants.dart';
import 'crypto.dart';
import 'paths.dart';

/// MeshCore on-air packet (`mesh::Packet` compatible).
///
/// Wire format: `header(1) | [transport_codes(4)] | path_len(1) | path(N) | payload(M)`.
class Packet {
  Packet();

  int header = 0x00;
  int pathLenByte = 0;
  int transportCode0 = 0;
  int transportCode1 = 0;
  Uint8List path = Uint8List(0);
  Uint8List payload = Uint8List(0);

  double snr = 0.0;
  int rssi = 0;

  int get routeType => header & phRouteMask;
  int get payloadType => (header >> phTypeShift) & phTypeMask;
  int get payloadVersion => (header >> phVerShift) & phVerMask;

  bool get hasTransportCodes =>
      routeType == routeTypeTransportFlood ||
      routeType == routeTypeTransportDirect;

  bool get isRouteFlood =>
      routeType == routeTypeFlood || routeType == routeTypeTransportFlood;

  bool get isRouteDirect =>
      routeType == routeTypeDirect || routeType == routeTypeTransportDirect;

  int get pathHashSize => PathUtils.getHashSize(pathLenByte);
  int get pathHashCount => PathUtils.getHashCount(pathLenByte);
  int get pathByteLength => PathUtils.getByteLength(pathLenByte);

  static int createHeader(int payloadType, int routeType,
          [int version = 0]) =>
      (routeType & phRouteMask) |
      ((payloadType & phTypeMask) << phTypeShift) |
      ((version & phVerMask) << phVerShift);

  void setPath(List<int> pathBytes, [int? encodedPathLen]) {
    path = Uint8List.fromList(pathBytes);
    if (encodedPathLen != null) {
      pathLenByte = encodedPathLen;
    } else {
      pathLenByte = PathUtils.encodePathLen(1, path.length);
    }
  }

  int get rawLength =>
      2 + pathByteLength + payload.length + (hasTransportCodes ? 4 : 0);

  Uint8List writeTo() {
    final out = BytesBuilder(copy: false)..addByte(header);
    if (hasTransportCodes) {
      out.addByte(transportCode0 & 0xFF);
      out.addByte((transportCode0 >> 8) & 0xFF);
      out.addByte(transportCode1 & 0xFF);
      out.addByte((transportCode1 >> 8) & 0xFF);
    }
    out.addByte(pathLenByte);
    out.add(path.sublist(0, pathByteLength));
    out.add(payload);
    return out.toBytes();
  }

  static Packet? readFrom(Uint8List data) {
    if (data.isEmpty) return null;
    final p = Packet();
    var idx = 0;
    p.header = data[idx++];
    if (p.payloadVersion > 1) {
      // Only versions 0-1 are currently supported.
      return null;
    }
    if (p.hasTransportCodes) {
      if (idx + 4 > data.length) return null;
      p.transportCode0 = data[idx] | (data[idx + 1] << 8);
      p.transportCode1 = data[idx + 2] | (data[idx + 3] << 8);
      idx += 4;
    }
    if (idx >= data.length) return null;
    p.pathLenByte = data[idx++];
    if (!PathUtils.isValidPathLen(p.pathLenByte)) return null;
    final pathBytes = p.pathByteLength;
    if (idx + pathBytes > data.length) return null;
    p.path = Uint8List.fromList(data.sublist(idx, idx + pathBytes));
    idx += pathBytes;
    p.payload = Uint8List.fromList(data.sublist(idx));
    return p;
  }

  /// SHA-256-based packet hash, used for ACKs and dedup.
  Uint8List calculatePacketHash() =>
      CryptoUtils.packetHash(payloadType, pathLenByte, payload);

  int calculateCrc() {
    final hash = calculatePacketHash();
    return hash[0] | (hash[1] << 8) | (hash[2] << 16) | (hash[3] << 24);
  }
}

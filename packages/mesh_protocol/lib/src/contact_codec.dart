import 'dart:typed_data';

import 'buffer.dart';
import 'constants.dart';
import 'models.dart';
import 'paths.dart';
import 'text.dart';

/// A decoded `CMD_ADD_UPDATE_CONTACT` record.
class CompanionContactRecord {
  const CompanionContactRecord({required this.contact, required this.hasGps});

  final Contact contact;

  /// Whether the record carried a GPS pair. When false, the existing location
  /// must be preserved.
  final bool hasGps;
}

/// Decode the companion contact-record body (after the command byte).
///
/// Missing trailing fields are optional: the name may be short/absent, GPS may
/// be omitted, and the last-modified timestamp falls back to [defaultLastmod].
/// Returns null for an invalid path length, name, or coordinate pair.
CompanionContactRecord? decodeCompanionContactRecord(
  Uint8List data, {
  int defaultLastmod = 0,
}) {
  if (data.length < 36) return null;
  final pubkey = Uint8List.fromList(data.sublist(0, pubKeySize));
  final advType = data[32];
  final flags = data[33];
  final pathLenByte = data[34];
  final int outPathLen;
  if (pathLenByte == 0xFF) {
    outPathLen = -1;
  } else if (PathUtils.isValidPathLen(pathLenByte)) {
    outPathLen = pathLenByte;
  } else {
    return null;
  }

  const pathStart = 35;
  const pathEnd = pathStart + maxPathSize;
  var path = Uint8List(0);
  if (outPathLen >= 0) {
    final pathBytes = PathUtils.getByteLength(outPathLen);
    if (data.length < pathStart + pathBytes) return null;
    path = Uint8List.fromList(data.sublist(pathStart, pathStart + pathBytes));
  }

  const nameStart = pathEnd;
  const nameEnd = nameStart + maxNameSize;
  Uint8List nameRaw;
  if (data.length >= nameEnd) {
    nameRaw = data.sublist(nameStart, nameEnd);
  } else if (data.length > nameStart) {
    nameRaw = Uint8List.fromList([
      ...data.sublist(nameStart),
      ...List<int>.filled(nameEnd - data.length, 0),
    ]);
  } else {
    nameRaw = Uint8List(maxNameSize);
  }
  final name = decodeContactNameBytes(nameRaw);
  if (name == null) return null;

  var lastAdvert = 0;
  var lat = 0.0;
  var lon = 0.0;
  var lastmod = defaultLastmod;
  final hasGps = data.length >= nameEnd + 12;
  if (data.length >= nameEnd + 4) {
    lastAdvert = BufferReader(data.sublist(nameEnd)).readUInt32Le();
  }
  if (hasGps) {
    final r = BufferReader(data.sublist(nameEnd + 4));
    final latMicros = r.readInt32Le();
    final lonMicros = r.readInt32Le();
    if (!isValidAdvertCoordinateMicros(latMicros, lonMicros)) return null;
    lat = latMicros / 1e6;
    lon = lonMicros / 1e6;
  }
  if (data.length >= nameEnd + 16) {
    lastmod = BufferReader(data.sublist(nameEnd + 12)).readUInt32Le();
  }

  return CompanionContactRecord(
    contact: Contact(
      publicKey: pubkey,
      name: name,
      advType: advType,
      flags: flags,
      outPathLen: outPathLen,
      outPath: path,
      lastAdvertTimestamp: lastAdvert,
      lastmod: lastmod,
      gpsLat: lat,
      gpsLon: lon,
    ),
    hasGps: hasGps,
  );
}

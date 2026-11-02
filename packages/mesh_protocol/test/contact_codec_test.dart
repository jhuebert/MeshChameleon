import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  Uint8List key([int first = 7]) => Uint8List(32)..[0] = first;

  test('round-trips the complete companion contact record', () {
    final contact = Contact(
      publicKey: key(),
      name: 'peer',
      advType: advTypeRepeater,
      flags: 0x11,
      outPathLen: 2,
      outPath: [0xAA, 0xBB],
      lastAdvertTimestamp: 0x11223344,
      gpsLat: 40.5,
      gpsLon: -96.25,
      lastmod: 0x55667788,
    );

    final record = decodeCompanionContactRecord(contact.toCompanionFrameBody());
    expect(record, isNotNull);
    expect(record!.hasGps, isTrue);
    final decoded = record.contact;
    expect(decoded.publicKey, contact.publicKey);
    expect(decoded.name, 'peer');
    expect(decoded.advType, advTypeRepeater);
    expect(decoded.flags, 0x11);
    expect(decoded.outPathLen, 2);
    expect(decoded.outPath, [0xAA, 0xBB]);
    expect(decoded.lastAdvertTimestamp, 0x11223344);
    expect(decoded.gpsLat, closeTo(40.5, 1e-6));
    expect(decoded.gpsLon, closeTo(-96.25, 1e-6));
    expect(decoded.lastmod, 0x55667788);
  });

  test('accepts an unknown route and a missing name/GPS', () {
    final data = (BufferWriter()
          ..writeBytes(key())
          ..writeByte(advTypeChat)
          ..writeByte(0)
          ..writeByte(0xFF)
          ..writeByte(0))
        .toBytes();

    final record = decodeCompanionContactRecord(data, defaultLastmod: 42);
    expect(record, isNotNull);
    expect(record!.hasGps, isFalse);
    expect(record.contact.outPathLen, -1);
    expect(record.contact.outPath, isEmpty);
    expect(record.contact.name, '');
    expect(record.contact.lastmod, 42);
  });

  test('pads a partial name and keeps the record valid', () {
    final data = (BufferWriter()
          ..writeBytes(key())
          ..writeByte(advTypeChat)
          ..writeByte(0)
          ..writeByte(0xFF)
          ..writeBytes(List.filled(maxPathSize, 0))
          ..writeString('ab'))
        .toBytes();

    final record = decodeCompanionContactRecord(data);
    expect(record, isNotNull);
    expect(record!.contact.name, 'ab');
    expect(record.hasGps, isFalse);
  });

  test('rejects short records, invalid paths, names, and coordinates', () {
    expect(decodeCompanionContactRecord(Uint8List(35)), isNull);

    final badPath = Contact(
      publicKey: key(),
      name: 'peer',
    ).toCompanionFrameBody();
    badPath[34] = 0xFE;
    expect(decodeCompanionContactRecord(badPath), isNull);

    final badCoords = Contact(
      publicKey: key(),
      name: 'peer',
      gpsLat: 100,
      gpsLon: 0,
    ).toCompanionFrameBody();
    expect(decodeCompanionContactRecord(badCoords), isNull);

    final badName = Contact(publicKey: key()).toCompanionFrameBody();
    badName[99] = 0xFF;
    expect(decodeCompanionContactRecord(badName), isNull);
  });
}

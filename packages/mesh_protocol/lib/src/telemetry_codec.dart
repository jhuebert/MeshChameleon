import 'dart:typed_data';

import 'buffer.dart';
import 'constants.dart';

/// Encode one CayenneLPP voltage entry: `channel | 0x74 | u16 BE`.
///
/// The value is millivolts divided by 10 (0.01 V units) and clamped to the
/// representable unsigned range.
Uint8List encodeTelemetryVoltage(int channel, int millivolts) => (BufferWriter()
      ..writeByte(channel)
      ..writeByte(0x74) // CayenneLPP voltage, 0.01 V
      ..writeUInt16Be((millivolts / 10).round().clamp(0, 0xFFFF)))
    .toBytes();

/// Encode the local node's voltage entry on the self-telemetry channel.
Uint8List encodeSelfVoltageTelemetry(int millivolts) =>
    encodeTelemetryVoltage(telemChannelSelf, millivolts);

/// Encode one CayenneLPP percentage entry: `channel | 0x78 | u8`.
///
/// Values outside 0-100 are clamped before encoding.
Uint8List encodeTelemetryPercentage(int channel, int percent) => (BufferWriter()
      ..writeByte(channel)
      ..writeByte(0x78) // CayenneLPP percentage
      ..writeByte(percent.clamp(0, 100)))
    .toBytes();

/// Encode one CayenneLPP GPS entry:
/// `channel | 0x88 | lat(3) | lon(3) | altitude(3)`.
///
/// Latitude and longitude are in 0.0001 degree units, altitude in 0.01 m
/// units. Non-finite coordinates raise [ArgumentError]; finite values are
/// clamped to the signed 24-bit range. A null altitude encodes as 0.
Uint8List encodeTelemetryGps(
  int channel,
  double latitude,
  double longitude,
  double? altitudeMeters,
) {
  if (!latitude.isFinite || !longitude.isFinite) {
    throw ArgumentError('GPS coordinates must be finite');
  }
  final w = BufferWriter()
    ..writeByte(channel)
    ..writeByte(0x88); // CayenneLPP GPS
  writeSigned24(w, (latitude * 10000).round());
  writeSigned24(w, (longitude * 10000).round());
  final altitude = altitudeMeters;
  writeSigned24(
    w,
    altitude == null || !altitude.isFinite ? 0 : (altitude * 100).round(),
  );
  return w.toBytes();
}

/// Write [value] as a big-endian two's-complement 24-bit integer.
void writeSigned24(BufferWriter w, int value) {
  final clamped = value.clamp(-0x800000, 0x7FFFFF);
  final encoded = clamped < 0 ? clamped + 0x1000000 : clamped;
  w
    ..writeByte((encoded >> 16) & 0xFF)
    ..writeByte((encoded >> 8) & 0xFF)
    ..writeByte(encoded & 0xFF);
}

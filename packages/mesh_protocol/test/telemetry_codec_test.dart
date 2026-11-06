import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('encodes the self voltage entry in 0.01 V units', () {
    expect(encodeSelfVoltageTelemetry(3700), [1, 0x74, 0x01, 0x72]);
  });

  test('clamps the voltage to the unsigned 16-bit range', () {
    expect(encodeSelfVoltageTelemetry(700000), [1, 0x74, 0xFF, 0xFF]);
    expect(encodeSelfVoltageTelemetry(-10), [1, 0x74, 0, 0]);
  });

  test('encodes percentage on the requested channel', () {
    expect(encodeTelemetryPercentage(1, 0), [1, 0x78, 0]);
    expect(encodeTelemetryPercentage(2, 1), [2, 0x78, 1]);
    expect(encodeTelemetryPercentage(1, 100), [1, 0x78, 100]);
  });

  test('clamps percentage to 0-100', () {
    expect(encodeTelemetryPercentage(1, -5), [1, 0x78, 0]);
    expect(encodeTelemetryPercentage(1, 101), [1, 0x78, 100]);
  });

  test('encodes positive and negative GPS coordinates exactly', () {
    expect(
      encodeTelemetryGps(1, 12.3456, -45.6789, null),
      [
        1,
        0x88,
        0x01,
        0xE2,
        0x40, // lat 12.3456
        0xF9,
        0x07,
        0xAB, // lon -45.6789
        0,
        0,
        0, // altitude
      ],
    );
  });

  test('encodes altitude in 0.01 m units, including negative values', () {
    expect(
      encodeTelemetryGps(1, 0, 0, 12.34),
      [1, 0x88, 0, 0, 0, 0, 0, 0, 0, 0x04, 0xD2],
    );
    expect(
      encodeTelemetryGps(1, 0, 0, -5.5),
      [1, 0x88, 0, 0, 0, 0, 0, 0, 0xFF, 0xFD, 0xDA],
    );
    expect(
      encodeTelemetryGps(1, 0, 0, 0),
      [1, 0x88, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    );
  });

  test('clamps finite coordinates to the signed 24-bit range', () {
    expect(
      encodeTelemetryGps(1, 1000, -1000, null).sublist(2, 8),
      [0x7F, 0xFF, 0xFF, 0x80, 0x00, 0x00],
    );
  });

  test('rejects non-finite coordinates', () {
    expect(
      () => encodeTelemetryGps(1, double.nan, 0, null),
      throwsArgumentError,
    );
    expect(
      () => encodeTelemetryGps(1, 0, double.infinity, null),
      throwsArgumentError,
    );
  });
}

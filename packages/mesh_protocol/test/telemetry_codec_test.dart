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
}

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('accepts only modes 0 through 2', () {
    expect(isValidPathHashMode(-1), isFalse);
    expect(isValidPathHashMode(0), isTrue);
    expect(isValidPathHashMode(1), isTrue);
    expect(isValidPathHashMode(2), isTrue);
    expect(isValidPathHashMode(3), isFalse);
  });

  test('clamps defensive internal callers into range', () {
    expect(clampPathHashMode(-1), 0);
    expect(clampPathHashMode(0), 0);
    expect(clampPathHashMode(2), 2);
    expect(clampPathHashMode(3), 2);
  });
}

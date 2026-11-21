import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/services/observation_models.dart';
import 'package:meshchameleon/widgets/identity_avatar.dart';

void main() {
  test('radio storage percentages require a valid physical reading', () {
    RadioHealth reading(int used, int total) => RadioHealth(
          millivolts: 0,
          storageUsedKb: used,
          storageTotalKb: total,
          sampledAt: DateTime.utc(2026),
        );
    expect(reading(25, 100).storageUsedPercent, 25);
    expect(reading(0, 100).storageUsedPercent, 0);
    expect(reading(1, 0).storageUsedPercent, isNull);
    expect(reading(-1, 100).storageUsedPercent, isNull);
    expect(reading(101, 100).storageUsedPercent, isNull);
    expect(reading(0, 1).ageAt(DateTime.utc(2025)), Duration.zero);
    expect(reading(0, 1).volts, 0);
  });

  test('configured zero has a one-second effective interval', () {
    const scope = GpsScope(
      identityId: 'a',
      identityName: 'Alpha',
      requested: true,
      configuredIntervalSeconds: 0,
    );
    expect(scope.effectiveIntervalSeconds, 1);
    expect(GpsScope.normalizeInterval(-1), 0);
    expect(GpsScope.normalizeInterval(90000), 86400);
  });

  test('avatar monograms preserve graphemes and stable palette selection', () {
    expect(IdentityAvatar.monogramFor(''), '?');
    expect(IdentityAvatar.monogramFor('  alpha'), 'A');
    expect(IdentityAvatar.monogramFor('👩‍🚀 astronaut'), '👩‍🚀');
    expect(IdentityAvatar.tintFor('Alpha'), IdentityAvatar.tintFor('alpha'));
    expect(
        IdentityAvatar.stableHash('Alpha'), IdentityAvatar.stableHash('Alpha'));
  });
}

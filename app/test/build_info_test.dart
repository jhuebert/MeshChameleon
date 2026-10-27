import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/services/build_info.dart';
import 'package:package_info_plus/package_info_plus.dart';

PackageInfo _packageInfo({
  String version = '0.1.0',
  String buildNumber = '1',
}) =>
    PackageInfo(
      appName: 'MeshChameleon',
      packageName: 'org.huebert.meshchameleon',
      version: version,
      buildNumber: buildNumber,
    );

void main() {
  test('formats injected commit, dirty state, and UTC build time', () {
    final info = BuildInfo.fromPackageInfo(
      _packageInfo(),
      commit: 'abcdef1234567890abcdef1234567890abcdef12',
      dirty: 'true',
      buildTime: '2026-10-26T18:57:00Z',
    );

    expect(info.versionLabel, '0.1.0 (1)');
    expect(info.shortCommit, 'abcdef123456');
    expect(info.commitLabel, 'abcdef123456 · dirty');
    expect(info.buildTimeLabel, '2026-10-26 18:57 UTC');
    expect(info.footerLabel, '0.1.0 (1) · abcdef123456 · dirty');
    expect(info.hasFullBuildMetadata, isTrue);
  });

  test('rejects invalid commit and build-time defines', () {
    final info = BuildInfo.fromPackageInfo(
      _packageInfo(),
      commit: 'not-a-sha',
      dirty: 'yes',
      buildTime: 'not-a-date',
    );

    expect(info.commit, isNull);
    expect(info.buildTime, isNull);
    expect(info.footerLabel, '0.1.0 · dev build');
    expect(info.commitLabel, 'unavailable');
    expect(info.buildTimeLabel, 'unavailable');
  });

  test('falls back to the product version when package info is unavailable',
      () async {
    final info = await BuildInfo.load(
      loadPackageInfo: () async => throw StateError('no platform'),
    );

    expect(info.version, productVersion);
    expect(info.buildNumber, isNull);
    expect(info.commit, isNull);
    expect(info.buildTime, isNull);
  });

  test('keeps the installed build number distinct from the version name', () {
    final info = BuildInfo.fromPackageInfo(
      _packageInfo(buildNumber: '1001'),
      commit: 'abcdef1',
      buildTime: '2026-10-26T18:57:00Z',
    );

    expect(info.version, '0.1.0');
    expect(info.buildNumber, '1001');
    expect(info.versionLabel, '0.1.0 (1001)');
  });
}

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Values injected by `scripts/build.sh` / `scripts/run.sh`.
///
/// Direct IDE builds intentionally leave these empty so the UI can say the
/// metadata is unavailable instead of showing a stale or invented hash/date.
const String _gitCommitDefine =
    String.fromEnvironment('MESHCHAMELEON_GIT_COMMIT');
const String _gitDirtyDefine =
    String.fromEnvironment('MESHCHAMELEON_GIT_DIRTY');
const String _buildTimeDefine =
    String.fromEnvironment('MESHCHAMELEON_BUILD_TIME');

/// Installed build identity shown in About & diagnostics and the Home footer.
class BuildInfo {
  const BuildInfo({
    required this.version,
    this.buildNumber,
    this.commit,
    this.commitDirty = false,
    this.buildTime,
    this.packageName,
  });

  /// Version name from the installed package (for example `0.1.0`).
  final String version;

  /// Installed build/version code. Android split APKs may report an ABI-adjusted
  /// value (for example `1001`) rather than the pubspec `+1`.
  final String? buildNumber;

  /// Full Git commit SHA, or null when the binary was built without the wrapper.
  final String? commit;

  /// Whether the working tree had uncommitted changes at build time.
  final bool commitDirty;

  /// Compile timestamp in UTC, or null when built without the wrapper.
  final DateTime? buildTime;

  final String? packageName;

  static Future<BuildInfo> load({
    Future<PackageInfo> Function()? loadPackageInfo,
  }) async {
    try {
      final packageInfo = await (loadPackageInfo ?? PackageInfo.fromPlatform)();
      return fromPackageInfo(packageInfo);
    } catch (_) {
      return fallback();
    }
  }

  static BuildInfo fromPackageInfo(
    PackageInfo packageInfo, {
    String commit = _gitCommitDefine,
    String dirty = _gitDirtyDefine,
    String buildTime = _buildTimeDefine,
  }) =>
      BuildInfo(
        version: packageInfo.version,
        buildNumber: packageInfo.buildNumber,
        commit: _parseCommit(commit),
        commitDirty: _parseDirty(dirty),
        buildTime: _parseBuildTime(buildTime),
        packageName: packageInfo.packageName,
      );

  /// Used when the platform package information or a build define is absent.
  static BuildInfo fallback() => BuildInfo(
        version: productVersion,
        commit: _parseCommit(_gitCommitDefine),
        commitDirty: _parseDirty(_gitDirtyDefine),
        buildTime: _parseBuildTime(_buildTimeDefine),
      );

  bool get hasCommit => commit != null;
  bool get hasBuildTime => buildTime != null;
  bool get hasFullBuildMetadata => hasCommit && hasBuildTime;

  String get shortCommit {
    final value = commit;
    if (value == null) return 'unknown';
    return value.length <= 12 ? value : value.substring(0, 12);
  }

  String get commitLabel => hasCommit
      ? '$shortCommit${commitDirty ? ' · dirty' : ''}'
      : 'unavailable';

  String get buildTimeLabel =>
      hasBuildTime ? _formatUtc(buildTime!) : 'unavailable';

  String get modeLabel =>
      kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug');

  String get platformLabel => Platform.operatingSystem;

  String get versionLabel => (buildNumber == null || buildNumber!.isEmpty)
      ? version
      : '$version ($buildNumber)';

  /// Compact text for the Home footer.
  String get footerLabel => hasCommit
      ? '$versionLabel · $shortCommit${commitDirty ? ' · dirty' : ''}'
      : '$version · dev build';

  /// Shared key/value rows for the About page and copied diagnostics.
  List<MapEntry<String, String>> get details => [
        MapEntry('Version', version),
        MapEntry('Build', buildNumber ?? 'unavailable'),
        MapEntry('Commit', commitLabel),
        MapEntry('Built', buildTimeLabel),
        MapEntry('Mode', modeLabel),
        MapEntry('Platform', platformLabel),
        MapEntry('Package', packageName ?? 'unavailable'),
      ];

  static String? _parseCommit(String raw) {
    final value = raw.trim().toLowerCase();
    if (value.isEmpty) return null;
    return RegExp(r'^[0-9a-f]{7,40}$').hasMatch(value) ? value : null;
  }

  static bool _parseDirty(String raw) {
    final value = raw.trim().toLowerCase();
    return value == '1' || value == 'true' || value == 'yes';
  }

  static DateTime? _parseBuildTime(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    return DateTime.tryParse(value)?.toUtc();
  }

  static String _formatUtc(DateTime value) {
    final utc = value.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.year}-${two(utc.month)}-${two(utc.day)} '
        '${two(utc.hour)}:${two(utc.minute)} UTC';
  }
}

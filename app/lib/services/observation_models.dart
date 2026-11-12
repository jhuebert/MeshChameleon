// Small immutable presentation values shared by the screens and the
// diagnostics snapshot.
//
// These are projections of app/device state, not new sources of truth: the
// managers remain authoritative for how observations are collected.

/// Read-only physical-radio health for the currently attached radio.
///
/// Backed by the shared hub's success-cache, so reading it never triggers a
/// device request and never refreshes the sample timestamp. Storage is in KiB
/// (the protocol's `*Kb` names are KiB despite the spelling).
class RadioHealth {
  const RadioHealth({
    required this.millivolts,
    required this.storageUsedKb,
    required this.storageTotalKb,
    required this.sampledAt,
  });

  final int millivolts;
  final int storageUsedKb;
  final int storageTotalKb;

  /// Wall-clock time of the successful read this sample came from.
  final DateTime sampledAt;

  double get volts => millivolts / 1000.0;

  /// Used/total storage as a percentage, or null when the reading cannot
  /// describe one (invalid used or total value).
  double? get storageUsedPercent {
    if (storageTotalKb <= 0 ||
        storageUsedKb < 0 ||
        storageUsedKb > storageTotalKb) {
      return null;
    }
    return (storageUsedKb / storageTotalKb) * 100;
  }

  Duration ageAt(DateTime now) {
    final age = now.difference(sampledAt);
    return age.isNegative ? Duration.zero : age;
  }
}

/// Editable phone-GPS preference as scoped to one identity.
///
/// The shared location service keeps the aggregate sampling picture; this
/// value describes only what the *active* identity requested, which is what
/// the Settings editor modifies.
class GpsScope {
  const GpsScope({
    required this.identityId,
    required this.identityName,
    required this.requested,
    required this.configuredIntervalSeconds,
  });

  static const int defaultIntervalSeconds = 900;
  static const int maxIntervalSeconds = 86400;

  /// Clamp and tolerate junk input: stored values are normalized to 0-86400.
  static int normalizeInterval(int seconds) =>
      seconds.clamp(0, maxIntervalSeconds);

  final String identityId;
  final String identityName;
  final bool requested;

  /// Configured `gps_interval` (0 maps to an effective 1 second).
  final int configuredIntervalSeconds;

  /// Effective cadence for this identity in seconds; stored 0 means 1 second.
  int get effectiveIntervalSeconds =>
      configuredIntervalSeconds > 0 ? configuredIntervalSeconds : 1;
}

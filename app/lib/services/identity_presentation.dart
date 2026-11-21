// Small presentation helpers for identity rows (Home, switcher, Identities).
// Selection ("Active") is rendered separately from availability.
import 'identity_runtime.dart';

/// Availability label for an identity; selection is not part of this.
String identityAvailabilityLabel(IdentitySummary summary) {
  if (!summary.enabled) return 'Disabled';
  if (summary.live) return 'Live';
  if (summary.unavailableReason != null) return 'Unavailable';
  return 'Offline';
}

/// Readable reason why an identity cannot be selected, or null when it can.
String? identityDisabledReason(IdentitySummary summary) {
  if (!summary.enabled) return 'Disabled — enable it to use it';
  if (summary.unavailableReason != null) return summary.unavailableReason;
  if (!summary.keyAvailable) return 'Key unavailable';
  return null;
}

/// Queue phrasing for the active identity (including the empty case).
String waitingToSyncLabel(int total) =>
    total == 0 ? 'No messages waiting to sync' : '$total waiting to sync';

/// Queued messages held by other identities, or 0 when none.
int otherIdentitiesWaiting(
  Iterable<IdentitySummary> identities,
  String? activeId,
) =>
    identities
        .where((summary) => summary.id != activeId)
        .fold(0, (sum, s) => sum + s.queuedDirect + s.queuedChannel);

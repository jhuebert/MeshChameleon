# Changelog

All notable changes to MeshChameleon are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- A dropped BLE or TCP companion now parks instead of ending the session: the
  proxy stops so the client sees the disconnect, but MeshChameleon keeps waiting
  (BLE `autoConnect` or a capped TCP retry schedule) and restores the live
  identities and proxy when the radio returns.
- Cancel now works during an initial connect, a reconnect grace period, and a
  parked wait, and the waiting state keeps the last device label visible.
- A parked recovery survives process death through session schema v2
  (`recoveryPending`/`recoveryServeProxy`) and re-arms on the next launch even
  when **Resume on launch** is off.

### Fixed

- Matched stock companion behavior for `APP_START` reserved bytes,
  per-command minimum lengths/error codes, `GET_CHANNEL`, 16-byte channel
  secrets, signed-message sender prefixes, reserved group-data type 0 receive,
  and the 16-message offline queue with channel-message eviction (oversized
  legacy queues are trimmed to the newest 16 on load).
- Contain failures from scheduled ACKs/replies when the radio link drops, and
  report device-link send failures with protocol error codes instead of
  counting them as internal errors.
- BLE Disconnect/Cancel calls `disconnect(queue: false)`, stale GATT handles are
  cleared before an active connect, and notify setup is retried before failing.
- Restored access to existing 0.2.0 identity keys by allowing the v10
  secure-storage backend to import the old Jetpack Security entries on first
  access.
- Serialized identity-catalog mutations so concurrent create/rename/activate
  operations cannot drop a newer identity.
- Kept unreferenced identity state directories for recovery instead of deleting
  them when the catalog was loaded from a stale backup.
- Quarantined an unreadable primary catalog and recovered interrupted backup
  restores, including old key snapshots, on the next launch.
- Serialized connect, disconnect, reconnect, and proxy start/stop transitions;
  cancelling during startup no longer leaves a ghost connected session.
- Dropped the device link after a query timeout so a late reply cannot satisfy
  the next command.
- Kept the device link alive after a raw-transmit timeout, quarantined the late
  reply, and gave raw transmits a 30 s acknowledgement window so a slow physical
  transmission no longer surfaces as a failed send and a duplicate client retry.
- Validated saved-session ports and kept a successful connection when the
  session or connection-history write fails.
- Isolated unreadable secure-storage slots to one unavailable identity.

### Changed

- The simulated companion is available in release builds.
- **Backup & restore** now opens from the home screen instead of Information.
- Identity menus use short action labels for unavailable choices.
- Identity keys use the `flutter_secure_storage` v10 cipher backend
  (AES-256-GCM with RSA-OAEP key wrapping); existing v9 keys migrate on first
  access.
- The foreground-service, package-info, and secure-storage plugins now support
  Flutter's built-in Kotlin.
- Saved-session and connection-history files are written atomically.

## [0.2.0] - 2026-11-01

First signed pre-Play build.

- In-app encrypted backup and restore.
- Battery optimization now opens Android settings.
- Release APKs use the future Play app signing key.

### Added

- Backup & restore: save or restore every identity, contact, channel, message,
  saved connection, and setting in one passphrase-encrypted file.

## [0.1.0] - 2026-10-28

### Added

- Initial development baseline: a virtual MeshCore companion served over TCP,
  multiple identities on one shared radio, BLE and TCP device links, a
  foreground service for background operation, a hardware-free simulator, and
  diagnostics with build metadata.

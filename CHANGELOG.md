# Changelog

All notable changes to MeshChameleon are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Serialized identity-catalog mutations so concurrent create/rename/activate
  operations cannot drop a newer identity.
- Kept unreferenced identity state directories for recovery instead of deleting
  them when the catalog was loaded from a stale backup.
- Quarantined an unreadable primary catalog and recovered interrupted backup
  restores, including old key snapshots, on the next launch.
- Serialized connect, disconnect, reconnect, and proxy start/stop transitions;
  cancelling during startup no longer leaves a ghost connected session.
- Dropped the device link after a request timeout so a late reply cannot satisfy
  the next command.
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

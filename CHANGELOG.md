# Changelog

All notable changes to MeshChameleon are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- The simulated companion is available in release builds.
- **Backup & restore** now opens from the home screen instead of Information.
- Identity menus use short action labels for unavailable choices.

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

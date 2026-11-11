# Security notes

This document records the security model and the initial-release review of
identity storage.
It is a description of the current implementation, not a guarantee—this is a
personal project and has not been independently audited.

## Assets

| Asset | Sensitivity | Where it lives |
|---|---|---|
| MeshCore identity private keys (64-byte expanded key: 32-byte scalar + 32-byte nonce, one per virtual identity) | **Secret.** Whoever holds one can sign adverts/messages and decrypt direct traffic as that identity. | Per-identity Android Keystore-backed secure storage (`meshcore_identity_v2/<id>`); headless `--identity-file` is plaintext hex with mode 0600. An app-facing client can export/import only the active identity over the TCP companion endpoint. |
| Contacts, channels, message queue, adverts, prefs | Private-ish. Reveals who/how you communicate. | `<app-support>/identities/<id>/node_state.json` (not encrypted at rest). |
| User backup file (`.mcbackup`) | **Secret.** Contains every identity key plus contacts, channels, messages, and settings, encrypted with a user passphrase. | Wherever the user saves it through the Android file picker. |
| The device's own identity | Not ours. The proxy never reads or adopts it. | Stays on the companion device; it is never reported in SELF_INFO or exposed in the UI. |

## Identity storage review

`IdentityStore` (`app/lib/services/identity_store.dart`) stores each 64-byte
MeshCore key as hex in a `meshcore_identity_v2/<identity-id>` slot in
`flutter_secure_storage` with:

```dart
AndroidOptions(resetOnError: false, migrateWithBackup: true)
```

- On Android, `flutter_secure_storage` v10 encrypts values with
  **AES-256-GCM** and wraps the data key with **RSA-OAEP-SHA256**; the wrapping
  key lives in the **Android Keystore**. This replaces the v9 Jetpack Security
  `EncryptedSharedPreferences` backend, whose entries are migrated on first
  access with a crash-resistant backup.
- `resetOnError` is disabled. An unreadable key is surfaced as unavailable and
  the catalog is preserved; storage failures never silently erase identities.
- The plugin requires API 23+; the app's `minSdk` is 24.
- Keys are **never** logged. Diagnostics identify identities by stable record id
  or public-key prefix only.
- The MeshChameleon UI has no per-identity reveal/import/export/regenerate
  controls. `CMD_EXPORT_PRIVATE_KEY` / `CMD_IMPORT_PRIVATE_KEY` operate only on
  the active virtual identity over the app-facing TCP companion endpoint (the
  protocol's approved local key operation; no app confirmation). The
  whole-catalog backup is a separate, passphrase-encrypted file (see
  [Backups](#backups)).
- Public keys are unique across identity records. A protocol import that would
  duplicate another identity's key, or clone the attached radio's own key, is
  rejected before storage changes.
- **Android backup is disabled** (`android:allowBackup="false"`). The
  Keystore-encrypted blob is useless off-device anyway, and this avoids
  cloud-exfiltrating contacts/message state.

### Pre-baseline data note

0.1.0 is the initial release baseline. Pre-0.1.0 development layouts (the
single-identity `meshcore_identity_v1` secure key and root `node_state.json`)
are ignored and a fresh identity is created. From 0.1.0 onward, any storage or
configuration schema change must migrate released data; see
`DEVELOPMENT.md#persistence-versions-and-migrations`.

## Backups

`BackupService` (`app/lib/services/backup_service.dart`) captures the identity
catalog, every 64-byte identity key, each identity's node state, the saved
session, and the network connection history. It encrypts that JSON with
AES-256-GCM using a key derived from the user passphrase with
PBKDF2-HMAC-SHA256 (210,000 iterations, random 16-byte salt, random 12-byte
nonce). The version, timestamp, KDF parameters, and nonce are authenticated as
additional data.

The passphrase is never stored or logged. Import validates the envelope version,
every identity key against its catalog public key, all state and settings, and
refuses unknown future versions before touching local data. A restore renames
the current identity directory to a recovery folder, writes through the normal
stores, and rolls back on failure. The newest recovery folder is kept;
older ones are pruned.

## What this does *not* address

- **No biometric/device-credential gate.** Access is bound to the app sandbox +
  Keystore, not to a user presence check.
- **Per-identity `node_state.json` files are not encrypted.** They hold contacts,
  channels, adverts, and the message queue. They are protected only by the app
  sandbox. Encrypting them (or moving them behind the same store) is future work.
- **Rooted/compromised device or a malicious local app with the same UID** can
  read anything the app can.
- **No key material is sent off-device.** There is no analytics, telemetry
  upload, or cloud component. The app-facing companion endpoint can export/import
  the *virtual* key; it has no additional authentication. The primary deployment
  reaches it over loopback on the same phone, but it listens on all interfaces,
  so do not expose it beyond a trusted phone and network.
- **Headless identity file is plaintext.** `--identity-file` stores the expanded
  key as hex in a mode-0600 file, replaced atomically through a private empty
  temp file. Without that flag the identity is memory-only and network imports
  last until process exit.
- **The local CLI endpoint has no extra authentication.** An app-facing client
  on the TCP/BLE transport can run allowlisted virtual commands and, on physical
  firmware v14+, explicitly allowed physical commands (including WiFi credential
  reads and radio preference changes). Keep the endpoint on trusted phones and
  networks. WiFi passwords are forwarded as CLI text but are never logged or
  cached by the proxy.
- **The companion endpoint is plaintext and unauthenticated.** The TCP listener
  has no TLS, password, or pairing layer, and BLE NUS is likewise local-only
  transport security. The TCP listener binds all interfaces, so any app on the
  phone can reach `127.0.0.1:<port>` and devices on the local network can reach
  the phone's IP. A client that can reach it can export/import the virtual
  identity, mutate virtual state, run virtual CLI, and use the allowlisted
  physical CLI subset. Keep it on a trusted phone and network; do not expose it
  to the internet.
- **Co-client ambiguity is not fixable in the proxy.** A second app talking
  directly to the physical companion can race replies on the shared radio link;
  the proxy cannot serialize external clients. Use one configuration client at a
  time.
- **Virtual storage is quota-limited, not confidential.** Each identity's 4 MiB
  partition bounds durable virtual state and returns explicit storage errors; it
  does not encrypt `node_state.json`.
- **Diagnostics are local and session-only.** About & diagnostics keeps counters
  in memory and shows local IP addresses, ports, BLE/device names, identity
  public-key prefixes, and recent log lines. **Copy diagnostics** is an explicit
  user action and writes that report to the clipboard; nothing is uploaded. The
  report never includes the 64-byte private identity or any expanded key
  material.

## Remote CLI and telemetry exposure

Remote CLI requires an authenticated/decrypted type-3 message from a persistent
virtual contact with flag `0x10`. Physical administration (radio, WiFi, reboot,
poweroff) is always denied remotely. Packet-hash dedup prevents duplicate
execution but is not a comprehensive anti-replay authorization scheme. Incoming
telemetry permissions use the owner's mode plus contact class flags and the
requester's inverse mask; a base grant is required. Raw/control packets from
unconsumed routes remain in the raw RX log but are not executed locally.

Phone battery percentage uses the base telemetry grant. Phone GPS additionally
requires the location grant and the local `gps=1` setting. Enabling `gps` is not
a sharing decision by itself: mesh telemetry permissions still decide which
contacts receive coordinates, while adverts include them only when
`advertLocPolicy` allows it. The app asks for Android location permission
(including background location for sampling while backgrounded) just in time;
denial leaves the setting persisted but suppresses fixes and diagnostics report
the blocker. Coordinates are never written to normal logs or copied diagnostics.
Backups include node preferences, so a backup carries each identity's last
known location. The foreground service declares the `location` type only while
location access is granted.

## Identity entry points

- **First run** — one identity is generated automatically with a 32-byte CSPRNG
  seed (`LocalIdentity.generate()`) and stored only as the expanded key.
- **Create** — the app wizard creates additional identities, inactive, with the
  same generation path. Only the display name is chosen in the UI.
- **Import** — the companion protocol accepts the 64-byte expanded key for the
  active identity after firmware-equivalent validation. Both identity forms can
  sign: 64-byte identities use the expanded Ed25519 key directly
  (`CryptoUtils.ed25519SignFromExpanded`, RFC 8032). See `DEVELOPMENT.md`.

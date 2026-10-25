# Security notes

This document records the security model and the M5 review of identity storage.
It is a description of the current implementation, not a guarantee—this is a
personal project and has not been independently audited.

## Assets

| Asset | Sensitivity | Where it lives |
|---|---|---|
| MeshCore identity private key (64-byte expanded key: 32-byte scalar + 32-byte nonce) | **Secret.** Whoever holds it can sign adverts/messages as this node and decrypt direct traffic. | Android Keystore-backed secure storage in the app; headless `--identity-file` is plaintext hex with mode 0600. An app-facing client can also export it over the local companion endpoint. |
| Contacts, channels, message queue, adverts, prefs | Private-ish. Reveals who/how you communicate. | `node_state.json` in the app support dir (not encrypted at rest). |
| The device's own identity | Not ours to hold; never read or exposed. | Stays on the companion device. |

## Identity storage review

`IdentityStore` (`app/lib/services/identity_store.dart`) stores the 64-byte
MeshCore key as hex in `flutter_secure_storage` with:

```dart
AndroidOptions(encryptedSharedPreferences: true)
```

- On Android this is Jetpack Security **`EncryptedSharedPreferences`**:
  AES-256-GCM for values, with the master key stored in the **Android Keystore**.
  This is preferred over the plugin's legacy default
  (`encryptedSharedPreferences: false`), which wraps an AES-CBC key with
  RSA/ECB/PKCS1Padding. Both are Keystore-backed, but GCM + AES-256 is the
  modern, non-malleable construction.
- `EncryptedSharedPreferences` requires API 23+; the app's `minSdk` is 24.
- The key is **never** logged. Log lines only ever contain a 4-byte public-key
  prefix (`_pubkeyPrefix()` in `app/lib/app_state.dart`).
- `exportKey()` returns the raw 64-byte key in response to the Identity screen's
  explicit "Reveal 64-byte key" action, or to an app-facing client's
  `CMD_EXPORT_PRIVATE_KEY` over the local companion endpoint (the protocol's
  approved local key operation; no app confirmation).
- **Android backup is disabled** (`android:allowBackup="false"`). The
  Keystore-encrypted blob is useless off-device anyway, and this avoids
  cloud-exfiltrating contacts/message state.

### Backend migration note

Switching to `EncryptedSharedPreferences` changes the on-disk format. Identities
written by an earlier debug build (legacy plugin backend) will not be readable
after this change—generate or re-import the key on such installs. This is a
pre-1.0 change; release installs start clean.

## What this does *not* address

- **Export is plaintext on screen.** Revealing the key puts it in the UI (and
  potentially the clipboard/screenshots). Treat that as a deliberate migration
  step, not a normal operation.
- **No biometric/device-credential gate.** Access is bound to the app sandbox +
  Keystore, not to a user presence check.
- **`node_state.json` is not encrypted.** It holds contacts, channels, adverts,
  and the message queue. It is protected only by the app sandbox. Encrypting it
  (or moving it behind the same store) is future work.
- **Rooted/compromised device or a malicious local app with the same UID** can
  read anything the app can.
- **No key material is sent off-device.** There is no analytics, telemetry
  upload, or cloud component. (Import-from-device does move the *device's* key
  from the companion to the phone over the local BLE/TCP link; that link is the
  OS transport, not an end-to-end-encrypted channel we control.) The local
  app-facing companion endpoint can export/import the *virtual* key; it has no
  additional authentication beyond the TCP/BLE transport, so do not expose it
  beyond trusted networks.
- **Headless identity file is plaintext.** `--identity-file` stores the expanded
  key as hex in a mode-0600 file, replaced atomically through a private empty
  temp file. Without that flag the identity is memory-only and network imports
  last until process exit.
- **The local CLI endpoint has no extra authentication.** An app-facing client
  on the TCP/BLE transport can run allowlisted virtual commands and, on physical
  firmware v14+, explicitly allowed physical commands (including WiFi credential
  reads and radio preference changes). Keep the endpoint on trusted networks.
  WiFi passwords are forwarded as CLI text but are never logged or cached by the
  proxy.

## Identity entry points

- **Generate** — 32-byte seed from a CSPRNG (`LocalIdentity.generate()`); the
  seed is retained in memory for signing and stored only as the expanded key.
- **Import** — accepts a 32-byte seed *or* the 64-byte expanded key. Both forms
  can sign now: the 64-byte form is the expanded Ed25519 key, which is all that
  RFC 8032 signing needs (`CryptoUtils.ed25519SignFromExpanded`). See
  `DEVELOPMENT.md`.
- **Import from the device (implemented)** — the Identity screen's **Import from
  connected device** sends `CMD_EXPORT_PRIVATE_KEY` (command 23) over the live
  device link and adopts the device's 64-byte key. The firmware enables export
  by default (its `arduino_base` build flags); hardened firmware replies
  `RESP_CODE_DISABLED`, which the app reports and ignores. The exported key is
  handled in memory only, never logged, and replaces the proxy identity through
  the shared running-node controller, so connected clients stay attached.

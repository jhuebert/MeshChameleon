# Security notes

This document records the security model and the initial-release review of
identity storage.
It is a description of the current implementation, not a guarantee—this is a
personal project and has not been independently audited.

## Assets

| Asset | Sensitivity | Where it lives |
|---|---|---|
| MeshCore identity private keys (64-byte expanded key: 32-byte scalar + 32-byte nonce, one per virtual identity) | **Secret.** Whoever holds one can sign adverts/messages and decrypt direct traffic as that identity. | Per-identity Android Keystore-backed secure storage (`meshcore_identity_v2/<id>`); headless `--identity-file` is plaintext hex with mode 0600. An app-facing client can export/import only the active identity over the local companion endpoint. |
| Contacts, channels, message queue, adverts, prefs | Private-ish. Reveals who/how you communicate. | `<app-support>/identities/<id>/node_state.json` (not encrypted at rest). |
| The device's own identity | Not ours. The proxy never reads or adopts it. | Stays on the companion device; it is never reported in SELF_INFO or exposed in the UI. |

## Identity storage review

`IdentityStore` (`app/lib/services/identity_store.dart`) stores each 64-byte
MeshCore key as hex in a `meshcore_identity_v2/<identity-id>` slot in
`flutter_secure_storage` with:

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
- Keys are **never** logged. Diagnostics identify identities by stable record id
  or public-key prefix only.
- The MeshChameleon UI has no reveal/import/export/regenerate controls.
  `CMD_EXPORT_PRIVATE_KEY` / `CMD_IMPORT_PRIVATE_KEY` operate only on the active
  virtual identity over the local companion endpoint (the protocol's approved
  local key operation; no app confirmation).
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

## What this does *not* address

- **No biometric/device-credential gate.** Access is bound to the app sandbox +
  Keystore, not to a user presence check.
- **Per-identity `node_state.json` files are not encrypted.** They hold contacts,
  channels, adverts, and the message queue. They are protected only by the app
  sandbox. Encrypting them (or moving them behind the same store) is future work.
- **Rooted/compromised device or a malicious local app with the same UID** can
  read anything the app can.
- **No key material is sent off-device.** There is no analytics, telemetry
  upload, or cloud component. The local app-facing companion endpoint can
  export/import the *virtual* key; it has no additional authentication beyond the
  TCP/BLE transport, so do not expose it beyond trusted networks.
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
- **The companion endpoint is plaintext and unauthenticated.** The TCP listener
  has no TLS, password, or pairing layer, and BLE NUS is likewise local-only
  transport security. A client that can reach it can export/import the virtual
  identity, mutate virtual state, run virtual CLI, and use the allowlisted
  physical CLI subset. Bind/expose it only on trusted networks.
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

## Identity entry points

- **First run** — one identity is generated automatically with a 32-byte CSPRNG
  seed (`LocalIdentity.generate()`) and stored only as the expanded key.
- **Create** — the app wizard creates additional identities, inactive, with the
  same generation path. Only the display name is chosen in the UI.
- **Import** — the companion protocol accepts the 64-byte expanded key for the
  active identity after firmware-equivalent validation. Both identity forms can
  sign: 64-byte identities use the expanded Ed25519 key directly
  (`CryptoUtils.ed25519SignFromExpanded`, RFC 8032). See `DEVELOPMENT.md`.

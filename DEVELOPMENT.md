# Development notes

## Running an end-to-end test without hardware

The pure-Dart packages include a stock-companion simulator (`FakeDeviceLink`)
and a shared radio bus (`FakeRadioBus`). The highest-value end-to-end test is
`packages/mesh_node/test/integration_test.dart`: a framed TCP client (a stand-in
for `meshcore-cli` / `meshcore-open`) connects to the proxy's `CompanionServer`,
which drives a `MeshNode` over a simulated device link, against a peer node on
the same simulated bus.

Run everything:

```sh
DART=~/dev/flutter/bin/dart FLUTTER=~/dev/flutter/bin/flutter ./scripts/check.sh
```

## Connecting a real client

Start the proxy (port defaults to 5000), then point a client at the phone's IP:

```sh
meshcli -t <phone-ip> -p 5000 infos ver clock contacts get_channels adv
```

`CLI_OK` for `infos` means the proxy's `SELF_INFO` (identity + radio params) is
correct.

## Radio units

The companion protocol is inconsistent: `SELF_INFO` and `CMD_SET_RADIO_PARAMS`
encode frequency in **kHz** (915000) and bandwidth in **Hz** (250000). The Dart
core normalises `RadioParams.frequencyHz` to true Hz and converts at the wire
boundary.

## Flood scope (regions)

`CMD_SET_FLOOD_SCOPE (54)` sets a send-scope override for flooded packets
(`[54, 0, key(16)]` sets it, `[54, 0]` resets it, and `[54, 1]` forces unscoped
flooding on fw v12+). `CMD_GET/SET_DEFAULT_FLOOD_SCOPE (64/63)` manage a
persisted default region scope. When a scope is active, flooded
adverts/direct/group sends are emitted as **transport-flooded** packets carrying
a 16-bit code: the first two bytes (LE) of
`HMAC-SHA256(scopeKey, [payloadType, ...payload])`, with `0x0000`/`0xFFFF`
reserved, matching the firmware's `TransportKey::calcTransportCode`. With no
scope set, packets are byte-for-byte unchanged. This is not hardware-validated.

## Binary and anonymous requests

`CMD_SEND_BINARY_REQ (50)` and `CMD_SEND_ANON_REQ (57)` both answer `SENT`
(`[6][flood][tag(4)][timeout(4)]`) with the request's real tag, and deliver the
reply as `PUSH_CODE_BINARY_RESPONSE`:
`[0x8C][reserved(1)][tag(4)][payload]` — the firmware's `onContactResponse`
layout, matched by `meshcore-open` (e.g. the region management and neighbors
screens). An anonymous request for an unknown target registers a zero-hop
contact first, mirroring the firmware. As with telemetry, the decrypted payload
is AES-block-padded, so a trailing partial block may be zero-filled.

## Contact sharing

Each `Contact` stores the last raw advert packet it was learned from
(`rawAdvert`), persisted with the contact. `CMD_EXPORT_CONTACT (17)` returns that
blob — or a freshly built self advert when no public key is supplied — which is
the `meshcore://<hex>` contact URI form. `CMD_SHARE_CONTACT (16)` re-transmits a
contact's saved advert zero-hop so nearby nodes can learn it, and
`CMD_IMPORT_CONTACT (18)` parses a blob and processes it as if it had just been
received (flood). Not hardware-validated.

## Allowed repeat frequencies

`CMD_GET_ALLOWED_REPEAT_FREQ (60)` relays the connected device's regulatory
ranges by forwarding command 60 to the device link
(`RadioLink.getAllowedRepeatFreq`) and returning the raw
`[lower(4)][upper(4)]...` bytes under `RESP_ALLOWED_REPEAT_FREQ (26)`.

## Raw data

`CMD_SEND_RAW_DATA (25)` takes `[path_len][path][payload]` and transmits a
`PAYLOAD_TYPE_RAW_CUSTOM` packet directly along the decoded path (minimum
4-byte payload), matching the firmware. Flood is not supported (a reserved
hash-width encoding is rejected with `ERR_CODE_UNSUPPORTED_CMD`), and the path
is used verbatim without adding an ACK.

`CMD_SEND_RAW_PACKET (65)` takes `[priority][packet bytes]`, parses the packet
and transmits it verbatim — the route type and path are whatever the packet's
header encodes, so no scope or route rewriting is applied. The priority byte is
accepted for protocol compatibility but the transport does not use it.

## Identity forms and signing

A fresh identity is generated from a 32-byte seed. The 64-byte MeshCore form
(`[scalar(32)][prefix(32)]`) is the expanded Ed25519 key: it is what the app
persists and what the device returns from `CMD_EXPORT_PRIVATE_KEY`. **Both forms
can sign** — `LocalIdentity` signs seed identities via `cryptography` and
64-byte identities directly from the expanded key
(`CryptoUtils.ed25519SignFromExpanded`, RFC 8032), so no seed recovery is needed.

## Import from the device

On the Identity screen, **Import from connected device** sends
`CMD_EXPORT_PRIVATE_KEY` (firmware command 23) over the live device link and
adopts the returned 64-byte key as the proxy identity. It requires a connected
device and firmware that permits export (enabled by default in the firmware's
`arduino_base` build flags; hardened builds reply `RESP_CODE_DISABLED`). On
success the link is dropped so the mesh node is rebuilt under the imported
identity on the next connect. The key is never logged.

## Identity storage

The identity is kept in Android Keystore-backed
`EncryptedSharedPreferences` (AES-256-GCM). Android backup is disabled
(`allowBackup="false"`). See `SECURITY.md` for the full model and its caveats,
including the backend-format note if you are upgrading a pre-1.0 install.

## Background execution (Android)

The proxy keeps the device link and the app-facing `ServerSocket` alive under a
`flutter_foreground_task` service (M0 shape A: the engine runs in the main
isolate). Two home-screen controls make that reliable:

- **Battery optimization** — prompts for an exemption and re-checks the status
  whenever the app returns to the foreground. Without it, Doze and OEM battery
  managers can suspend the background link.
- **Resume on launch** — when enabled, the app remembers the last device target
  (TCP host/port or BLE remote id) plus the proxy port in
  `<app-support>/session.json` (`SessionStore`), and reconnects the device and
  restarts the proxy on the next launch.

This is a *launch* resume, not a true boot resume. With shape A the engine runs
in the main isolate, which Android does not start at boot; the proxy cannot come
back automatically after a reboot until the user opens the app. Boot resume would
require the shape-B engine-in-task-isolate design (plan §4).

## Release signing

Release builds are signed with your own keystore when a `key.properties`
(git-ignored) is present, and fall back to the debug key otherwise. To configure:

```sh
cd app/android
cp key.properties.example key.properties   # then edit the paths/passwords
keytool -genkeypair -v -keystore upload-keystore.jks \
  -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

The Android `applicationId` is `org.huebert.meshchameleon` (matching the
`namespace` and `MainActivity` package).

## Building the app

```sh
cd app
~/dev/flutter/bin/flutter build apk --debug
~/dev/android-sdk/platform-tools/adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

## Branding (icon + splash)

The app/product name is **MeshChameleon**. Source artwork lives in
`app/assets/branding/`:

- `icon.png` — full-bleed square icon (legacy / non-adaptive).
- `icon_foreground.png`, `icon_monochrome.png`, `icon_background.png` — adaptive
  icon layers (foreground, themed-monochrome, background).
- `splash_logo.png` — splash logo; `wordmark.png` — splash wordmark.
- `source/` — the editable SVGs (`mark.svg` is the chameleon mark; render with
  `rsvg-convert`). These are the source of truth; the PNGs are derived.

Configuration is in two files at `app/`:

- `flutter_launcher_icons.yaml` — launcher/adaptive/monochrome icons.
- `flutter_native_splash.yaml` — native splash (dark brand color `#0C1E1B`,
  logo + wordmark, Android 12 splash).

Regenerate after editing the source art:

```sh
cd app
~/dev/flutter/bin/dart run flutter_launcher_icons -f flutter_launcher_icons.yaml
~/dev/flutter/bin/dart run flutter_native_splash:create --path=flutter_native_splash.yaml
```

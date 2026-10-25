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

The same simulator is also reachable without writing a test: from the Linux
desktop app's **Simulated companion** entry, or from the headless CLI below.

If `meshcli` is installed, the optional external-client smoke test is:

```sh
cd packages/mesh_node
dart run tool/proxy_cli.dart --simulated --proxy-port 5099
# in another shell
meshcli -t 127.0.0.1 -p 5099 infos ver clock
```

The 1.18 signoff used `meshcore-cli v1.6.6` against this simulated proxy. It
reported firmware code 14 / `v1.18.0` and the virtual board. This is a client
handshake check, not radio or hardware validation.

## Compatibility target and intentional differences

The virtual companion advertises MeshCore 1.18 (`DEVICE_INFO` fw code 14,
version `v1.18.0`) with the virtual board string, 350-contact/40-channel
capacities, 4 MiB virtual storage, and the virtual identity/capabilities. The
following differences from a bare physical companion are intentional and are
not bugs:

- No automatic physical state writes: virtual preferences, contacts, channels,
  paths, queues, malformed inputs and storage errors never silently reconfigure
  the radio.
- Physical setters await device confirmation. `SET_RADIO_PARAMS` saves firmware
  prefs; saved values are not the live channel until the device reboots. Read
  back SELF_INFO and treat `saved-only` state separately from active RF.
- The virtual clock is host-derived. SET_DEVICE_TIME and timezone changes never
  touch the phone/radio RTC.
- Only a minimal telemetry surface is synthesized: fresh physical voltage plus
  virtual GPS when permitted. No physical GPS, MCU temperature, environment
  sensors, or sensor-node subscription server is fabricated.
- PIN and factory reset remain disabled; there is no remote or binary reset
  alias. The only reset is the explicit app-only virtual reset.
- Remote physical administration is denied. A remote CLI peer can run virtual
  commands only when its contact has flag `0x10`.
- Decoders reject truncated/oversized/unsafe values rather than reproducing
  `atoi`/`atof` acceptance. Persistence failures return honest errors.

Other deliberate limits: no dependency upgrades, no multi-virtual-companion
support, no iOS/USB transport work, no virtual repeater routing/forwarding, no
mandatory authentication redesign, and no sensor-node implementation.

## Co-client and raw-modem limitations

The proxy requires the physical companion to behave as an exclusive raw-radio
modem. A second app/BLE/TCP client talking to the same stock companion can
receive or consume replies concurrently, and the firmware broadcasts CLI replies
to every enabled interface. The proxy cannot serialize an external client. Do not
run another configuration client against the same radio during a session.

Direct-route semantic delivery requires a consumed zero-hop route; flooded or
still-in-transit packets are raw-logged but not executed locally. This is not a
repeater: no packet forwarding is implemented.

## Virtual storage and quota

Contacts (350), channels (40), queued messages, advert blobs/path cache and
sensor preferences share a deterministic 4 MiB virtual partition enforced before
publish. Quota failures are reported as storage/table-full errors; the app does
not delete broad directories or physical radio state to recover. See
`SECURITY.md` for at-rest storage.

## Linux desktop and headless proxy

Two hardware-free targets share the pure-Dart core:

- **Linux desktop** (`app/linux/`) — the real UI. BLE is hidden off mobile
  because there is no desktop `flutter_blue_plus` implementation; the
  debug/profile-only **Simulated companion** entry drives the real `MeshNode`
  and `CompanionServer` from an in-memory `FakeDeviceLink`.
- **Headless CLI** (`packages/mesh_node/tool/proxy_cli.dart`) — no Flutter, no
  GUI, TCP device link only.

Build dependencies on Arch (GTK3, libsecret, and pkg-config are usually already
present):

```sh
sudo pacman -S --needed clang cmake ninja
```

Run the desktop app:

```sh
cd app
~/dev/flutter/bin/flutter run -d linux
```

Run the headless proxy:

```sh
cd packages/mesh_node
~/dev/flutter/bin/dart run tool/proxy_cli.dart --simulated
~/dev/flutter/bin/dart run tool/proxy_cli.dart --device 192.168.1.50:5000
```

Other options: `--proxy-port` (default 5000, `0` picks a free port),
`--identity-file`, and `--state-dir` (persist contacts/channels/queue). Without
`--identity-file` the identity is regenerated each run, so every launch presents
a new `SELF_INFO` public key.

`--identity-file` writes the proxy's private identity as **plaintext hex at mode
0600**. Use it only for development; the phone app's Keystore-backed storage is
the real model (see `SECURITY.md`).

Desktop builds have no BLE device link and no background service — desktop has
no process suspension to defend against, so the link simply stays up while the
app runs. None of this is hardware-validated.

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

## Radio changes and device reboot

`CMD_SET_RADIO_PARAMS (11)` **saves** the new radio prefs but does not retune the
live radio until the device reboots; `SELF_INFO` reports the saved prefs, so it
can read back the new values while the radio is still on the old channel. A real
client therefore sends `CMD_REBOOT (19)` after changing radio settings.

`CMD_REBOOT` matches the firmware: it reboots the **device** (the firmware reboots
the hardware so saved prefs take effect). The proxy does that on
`RadioLink.reboot()` (a fire-and-forget `[19]["reboot"]` frame — the firmware
reboots without replying) in addition to its soft node-engine restart. The device
link will drop and the app reconnects it.

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

## CLI commands and self telemetry

`CMD_RUN_CLI_COMMAND (66)` (fw v14+) returns the device's CLI text as
`RESP_CODE_CLI_REPLY (29)` (`[29][utf8 text]`), matching the firmware; on older
firmware the proxy answers `ERR`. `CMD_SEND_TELEMETRY_REQ (39)` with a 3-byte
payload is the `'self'` telemetry request (firmware `len == 4`): the proxy
answers with its own CayenneLPP telemetry (battery voltage on the self channel)
as `PUSH_CODE_TELEMETRY_RESPONSE (0x8B)`.

Flooded request replies (login/status/telemetry/binary) can take **~15-25 s** to
arrive, because the repeater has to complete/return the path.

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
header encodes, so no scope or route rewriting is applied. The supplied priority
byte is passed through to the device transport.

## Disabled and key commands

`SET_DEVICE_PIN (37)` and `FACTORY_RESET (51)` receive the one-byte
`RESP_CODE_DISABLED (15)` response and never alter the device or app state.

`EXPORT_PRIVATE_KEY (23)` and `IMPORT_PRIVATE_KEY (24)` operate only on the
**virtual** identity. Export returns the active 64-byte key; import validates the
derived prefix and symmetric non-zero ECDH with the upstream test keypair, then
persists before switching. Neither sends key material to or reads it from the
physical companion. This is a deliberate local protocol operation with no extra
app confirmation, so treat the TCP/BLE endpoint as trusted. The Identity screen
also offers an explicit **Import from connected device** action, which *does*
read the physical device's exported key and adopts it as the virtual identity.

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
success it uses the same validated virtual replacement/persistence path as a
manual import, keeps the device link and connected clients up, and never logs the
key. The device's own identity is not exposed in SELF_INFO.

## Local endpoint and credential exposure

The app-facing companion endpoint has **no authentication or transport
encryption** beyond the local TCP/BLE link. Anything that can reach it can read
the virtual identity, import a replacement, add/remove contacts, send mesh
traffic, run virtual CLI commands, and—on physical firmware v14+—run the
allowlisted physical CLI subset. That subset includes WiFi SSID/password reads
and radio preference changes. WiFi passwords are forwarded as CLI text and are
never logged, cached, or truncated by the proxy, but they are still exposed to a
trusted-network client and to the radio firmware. Do not expose the listener on
an untrusted network.

## Hardware validation

Simulator/byte-level conformance does not prove hardware behavior. BLE/TCP
transports, RF immediate-vs-reboot application, WiFi reconfiguration, client
repeat, independent physical DMs, remote CLI, sensor telemetry, and Android
background/Doze survival remain a separate **PENDING** hardware matrix. No live
adverts/TX or firmware flashing is part of the default test gate.

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

Desktop:

```sh
cd app
~/dev/flutter/bin/flutter build linux --debug
```

## Branding (icon + splash)

The app/product name is **MeshChameleon**. Source artwork lives in
`app/assets/branding/`:

- `icon.png` — full-bleed square icon (legacy / non-adaptive).
- `icon_foreground.png`, `icon_monochrome.png`, `icon_background.png` — adaptive
  icon layers (foreground, themed-monochrome, background).
- `splash_logo.png` — splash logo; `wordmark.png` — splash wordmark.
- `source/` — the editable SVGs (render with `rsvg-convert`). These are the
  source of truth; the PNGs are derived:
  - `mark.svg` — the chameleon mark on transparent, tightly cropped
    (`splash_logo.png`).
  - `icon_full.svg` — full-bleed square icon (`icon.png`).
  - `background.svg`, `foreground.svg`, `monochrome.svg` — adaptive icon
    layers at 1024×1024; the foreground/monochrome art sits inside the 66/108
    safe-zone circle.

Configuration is in two files at `app/`:

- `flutter_launcher_icons.yaml` — launcher/adaptive/monochrome icons. The
  foreground/monochrome SVGs already keep the art inside the adaptive-icon safe
  zone, so `adaptive_icon_foreground_inset` is `0`.
- `flutter_native_splash.yaml` — native splash (dark brand color `#0C1E1B`,
  logo + wordmark, Android 12 splash).

Regenerate after editing the source art. First render the derived PNGs from the
SVGs with `rsvg-convert` and ImageMagick, then run the two Dart tools:

```sh
cd app
rsvg-convert -w 1024 -h 1024 assets/branding/source/icon_full.svg -o assets/branding/icon.png
rsvg-convert -w 1024 -h 1024 assets/branding/source/background.svg -o assets/branding/icon_background.png
rsvg-convert -w 1024 -h 1024 assets/branding/source/foreground.svg -o assets/branding/icon_foreground.png
rsvg-convert -w 1024 -h 1024 assets/branding/source/monochrome.svg -o assets/branding/icon_monochrome.png
# mark.svg is tightly cropped, so centre it on a padded 1152×1152 canvas
# (620×408 keeps the art inside the Android 12 splash safe circle).
rsvg-convert -w 620 -h 408 assets/branding/source/mark.svg -o /tmp/mark.png
magick -size 1152x1152 xc:none /tmp/mark.png -gravity center -composite assets/branding/splash_logo.png

~/dev/flutter/bin/dart run flutter_launcher_icons -f flutter_launcher_icons.yaml
~/dev/flutter/bin/dart run flutter_native_splash:create --path=flutter_native_splash.yaml
```

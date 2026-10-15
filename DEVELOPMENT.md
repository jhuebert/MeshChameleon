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

## 64-byte identity import

Fresh identities are generated from a 32-byte seed and can sign. Importing only
the 64-byte MeshCore expanded key (`[scalar][nonce]`) allows advertising,
public-key derivation, and ECDH, but not signing — the seed is not recoverable
from the expanded form. Re-import the 32-byte seed to retain signing.

## Identity storage

The identity is kept in Android Keystore-backed
`EncryptedSharedPreferences` (AES-256-GCM). Android backup is disabled
(`allowBackup="false"`). See `SECURITY.md` for the full model and its caveats,
including the backend-format note if you are upgrading a pre-1.0 install.

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

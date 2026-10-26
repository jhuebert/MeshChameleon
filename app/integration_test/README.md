# Hardware-in-the-loop tests

These tests exercise real transports and, in some cases, real RF. They are
**not** part of `scripts/check.sh` and must be run explicitly against a test
rig. No device name, host, IP address, or peer key is built in; supply them with
`--dart-define`.

Run from `app/`:

```sh
flutter test integration_test/<test>.dart -d <device-id> \
  --dart-define=BLE_NAME=<advertised name substring>
```

`<device-id>` is a Flutter device (an Android phone for BLE tests, or `linux`
for TCP-only tests).

## Android BLE

| Test | Required defines | Notes |
|---|---|---|
| `android_ble_scan_test.dart` | none | Scan-only; never connects. |
| `android_ble_identify_test.dart` | `BLE_NAME` | Read device/SELF_INFO/battery and run an ephemeral proxy handshake. |
| `android_ble_battery_test.dart` | `BLE_NAMES` (comma-separated) | Battery freshness and virtual-storage reporting for each named companion. |
| `android_ble_identity_switch_test.dart` | `BLE_NAME`, optional `PROXY_PORT` | Two live identities; active identity switch over a stable listener. |
| `android_ble_resume_test.dart` | `BLE_NAME`, optional `PROXY_PORT` | Persisted auto-resume into a fresh `AppState`. |
| `android_ble_ui_test.dart` | `BLE_NAME`, optional `PROXY_PORT`, `BACKGROUND_SECONDS`, `TEST_FW13` | Real ConnectScreen, foreground service, proxy, optional background interval. |
| `android_ble_reconnect_test.dart` | `BLE_NAME`, optional `PROXY_PORT` | **Reboots the radio** while a client is attached. |
| `android_ble_rf_test.dart` | `BLE_NAME`, `PEER_HOST`, `PEER_PUBKEY_HEX`, optional `PEER_PORT` (9505) | **Transmits one RF direct message** to a peer companion; removes the contact afterward. |
| `ble_mesh_test.dart` | `BLE_NAME`; optional `DO_TX`, `DO_ADVERT`, `CHANNEL_NAME`, `CHANNEL_PSK_HEX`, `PEER_PUBKEY_HEX`, `PEER_HOST`, `PEER_PORT`, `ECHO_RX` | Scan/connect/handshake; on-air phase only with `DO_TX=true`. |
| `repeater_validation_test.dart` | `BLE_NAME`, `REPEATER_PUBKEY_HEX`, `REPEATER_PASSWORD`; optional `REPEATER_FREQ_HZ`, `REPEATER_BW_HZ`, `REPEATER_SF`, `REPEATER_CR` | **Transmits RF** to log in to a repeater and read status/telemetry. Restores the original radio settings. |

## Linux / TCP

These run against a companion exposed over TCP (for example a WiFi companion or
a `proxy_cli` instance).

| Test | Required defines | Notes |
|---|---|---|
| `tcp_lifecycle_test.dart` | `DEVICE_HOST`, optional `DEVICE_PORT` (5000) | Five attach/detach cycles, then **reboots the radio** with a client attached. |
| `multi_identity_live_test.dart` | `DEVICE_HOST`, `PEER_HOST`, `PEER_PUBKEY_HEX`, optional `DEVICE_PORT` (5000), `PEER_PORT` (9505) | Three live identities, inactive queueing, activation, and local mirroring. **Transmits RF** direct messages. |

Example:

```sh
flutter test integration_test/tcp_lifecycle_test.dart -d linux \
  --dart-define=DEVICE_HOST=192.0.2.10
```

## Warnings

- RF tests consume airtime and may be heard by other nodes. Use an isolated
  channel or an adjacent test peer, and keep transmissions sparse.
- Reboot tests drop the device link; the app must be allowed to reconnect.
- The proxy assumes exclusive ownership of the companion. Do not run another
  configuration client against the same radio during a test.
- Results are not hardware validation unless they were actually run on the named
  hardware. Record the device/firmware used.

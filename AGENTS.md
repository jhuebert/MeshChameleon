# Agent Guide — MeshChameleon (MeshCore companion proxy)

## Project

Standalone Android-first Flutter/Dart app that presents a MeshCore companion
protocol TCP endpoint to a client while holding its own identity on the phone
and using a stock companion device as a raw radio. The app/product name is
**MeshChameleon**. iOS is deferred.

This is a personal project under `jhuebert/MeshChameleon`. The
reference projects in the workspace (`meshcore-open/`, `openhop_core/`, and
`MeshCore/`) are read-only: do not edit them as part of this project. Port or
adapt only the smallest necessary protocol logic, retain MIT attribution, and
keep `ATTRIBUTION.md` accurate.

## Before starting work

1. Read `PROGRESS.md` for the current implementation state and immediate next
   steps.
2. Read `plans/2026-10-14-meshcore-companion-proxy-android.md` for scope,
   protocol layouts, risks, and milestones.
3. Check `git status` before editing. The plan and progress note are temporary
   handoff files and must remain untracked; do not stage, commit, or push them.
4. Inspect the relevant package code and reference implementation before
   changing protocol behavior.

## Repository layout

- `packages/mesh_protocol/` — pure-Dart protocol constants, codecs, identity,
  crypto, packet models/builders, and frame codec.
- `packages/companion_server/` — app-facing TCP listener, serial frame parsing,
  command dispatch, and asynchronous push frames.
- `packages/mesh_node/` — node state and companion logic, driven by `RadioLink`.
- `packages/device_link/` — pure-Dart `RadioLink` SPI, TCP device client, and
  fake device/radio bus for tests.
- `app/` — Flutter UI, secure identity storage, BLE NUS transport, and app
  orchestration.
- `scripts/check.sh` — full analysis and test gate.
- `plans/` and `PROGRESS.md` — temporary implementation handoff material; do
  not commit these files unless Jason explicitly asks.

Keep protocol/core packages free of Flutter or Android imports. Platform code
belongs in `app/`.

## Current state and next milestone

The MeshCore 1.18 virtual-companion handoff (T01–T16) is implemented: strict
176-byte framing, virtual routing/capabilities/state, persistence and quota,
battery/storage, validated identity import/export, allowlisted CLI, lifecycle,
app-only reset, permission-controlled remote CLI, telemetry, and raw/control
endpoints. The pure-Dart simulator drives a hardware-free full-stack TCP test;
the external hardware matrix remains pending. The Android background-execution
shape is still the main-isolate foreground-service design, and background/Doze
survival has not been hardware-validated.

Multi-identity management is implemented: all catalog identities run live on
one shared radio, the active identity is served over the companion endpoint,
and outbound packets are mirrored in-process to the other live identities after
the RF send. Per-identity keys live in
`meshcore_identity_v2/<id>` secure slots and state in
`<support>/identities/<id>/node_state.json`; there is intentionally no migration
from the old single-identity layout. The attached radio's own companion identity
cannot be messaged through the virtual stack and unicasts to it are rejected.

Do not claim hardware validation unless it was run against real hardware. BLE,
multi-identity radio behavior, and background execution are currently not
hardware-validated.

## Development and verification

Flutter stable / Dart are expected. In this environment the SDK is at
`~/dev/flutter`; add `~/dev/flutter/bin` to `PATH` if needed.

Run all checks from the repo root:

```sh
DART=~/dev/flutter/bin/dart FLUTTER=~/dev/flutter/bin/flutter ./scripts/check.sh
```

This runs `dart analyze` and `dart test` for each pure-Dart package, then
`flutter analyze` and `flutter test` for the app. Run this before handing off
changes and address any new failures. For narrow iteration, run the relevant
package checks, then the full script before finishing.

## Protocol constraints and known gotchas

- TCP companion frames are `'<'` (0x3C) + uint16 LE length + payload inbound
  and `'>' (0x3E) + uint16 LE length + payload` outbound. The MeshCore 1.18
  limit is **176 payload bytes**, plus the 3-byte TCP header (179 bytes total);
  firmware `MAX_FRAME_SIZE` excludes that header. The server accepts only
  `'<'`, and the TCP device link accepts only `'>'`. BLE NUS carries a raw
  payload per write/notify without the TCP header, also limited to 176 bytes.
  Group-data TX over a stock companion is capped at **157** application bytes:
  158+ data bytes pad to a 176-byte ciphertext and need a 186-byte
  `SEND_RAW_PACKET` frame, which 1.18 firmware silently drops (the radio stays
  alive). The theoretical on-air group-data cap is 165 and channel-data RX
  pushes allow 167; a long route path reduces the TX cap further. Group **text**
  has a separate budget because the plaintext is `timestamp | flags |
  "<name>: <message>"`: with an empty/flood path the message text is at most
  `153 - UTF-8(name)` bytes (for example 144 bytes for `HIL Alpha`).
- `SELF_INFO` and `CMD_SET_RADIO_PARAMS` frequency fields are in **kHz** on
  the wire, while bandwidth is in **Hz**. `RadioParams.frequencyHz` is
  normalized to Hz internally; convert only at protocol boundaries.
- `CMD_DEVICE_QUERY` reports `max_contacts / 2` in one byte. The server must
  clamp its reported contacts to the representable range.
- `app_target_ver >= 3` selects the V3 direct/channel message response layout;
  preserve the value sent by the client in `DEVICE_QUERY` / `APP_START`.
- `PUSH_CODE_LOG_RX_DATA (0x88)` has `[code][snr*4][rssi][raw on-air packet]`.
  Only the raw packet should be delivered to `MeshNode.process` logic.
- The device identity is not the proxy identity. Do not expose it in `SELF_INFO`
  or use its high-level contact/message stack.
- Never log private or expanded identity key material. The private identity is
  stored through `flutter_secure_storage`; app UI reveal is an explicit user
  action, while the local companion protocol also exposes explicit export/import
  commands (the endpoint is trusted-network/plaintext).
- Firmware raw TX and path preservation, direct-route delivery, and Android
  background behavior remain empirical risks: keep their tests/spike outcomes
  documented and avoid presenting assumptions as verified facts.

## Change and git discipline

- Keep changes focused and match surrounding Dart/Flutter style. Do not change
  the reference repos or upgrade dependencies as drive-by work.
- Add regression tests for protocol behavior and keep the simulator tests
  hardware-free. Update `ATTRIBUTION.md` when adapting additional external code.
- Do not create a GitHub issue, PR, release, or publish artifacts without
  Jason's explicit request. Pushing code to the personal repo is allowed when
  Jason explicitly requests it.
- Do not commit the temporary plan or progress files. For other changes, make
  commits only when requested or when Jason has clearly asked for a commit; never
  bundle temporary handoff notes with implementation commits.

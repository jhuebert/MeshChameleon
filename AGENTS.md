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

M1 app skeleton/device link and the M2 companion-server core are implemented.
The pure-Dart simulator supports a hardware-free full-stack integration test.
See `PROGRESS.md` for detail and known limitations.

The next planned work is the M0 Android background-execution spike: test a
listening `ServerSocket` and persistent BLE link under a foreground service,
including background/Doze behavior, then record the choice between a main-isolate
engine and a foreground-task-isolate engine. Continue with M3 persistence and
remaining companion handlers after that feasibility work.

Do not claim hardware validation unless it was run against real hardware. BLE
and background execution are currently not hardware-validated.

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
  and `'>' (0x3E) + uint16 LE length + payload` outbound. Payload maximum is
  169 bytes (`MAX_FRAME_SIZE` 172 includes 3-byte framing header). BLE NUS
  carries a raw frame per write/notify.
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
  stored through `flutter_secure_storage`; exports must be explicit user actions.
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

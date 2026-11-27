# Agent Guide: MeshChameleon

## Project & ownership

Standalone Android-first Flutter/Dart app that presents a MeshCore companion
protocol TCP endpoint to a client while holding its own identity on the host and
using a stock companion device as a raw radio. It ships for Android and for
Linux, macOS and Windows desktop. The app and product name is **MeshChameleon**.
iOS is deferred.

This is a personal project under `jhuebert/MeshChameleon`. The reference
projects in the workspace (`meshcore-open/`, `openhop_core/` and `MeshCore/`) are
read-only: do not edit them as part of this project. Port or adapt only the
smallest necessary protocol logic, retain MIT attribution and keep
`ATTRIBUTION.md` accurate.

## Agent conduct

These rules apply to every change, including documentation-only changes.

- **Ask before codifying a pattern.** When a way of working recurs (a convention
  applied more than once, a preference stated twice, a pattern from a finished
  change), propose wording plus a one-line rationale and ask before adding it
  here. Never follow an unwritten rule silently, and never edit this file on
  your own initiative.
- **Commit only when asked.** Commit when Jason asks or clearly wants one.
  Never bundle unrelated cleanup with an implementation commit.
- **Ask before publishing.** Do not create a GitHub issue, PR, release, tag, or
  published artifact, or push to a remote without Jason's explicit request.
  Pushing to the personal repo is allowed only when Jason explicitly requests
  it.
- **No em dashes anywhere.** In this guide, project docs, code comments, commit
  messages, CLI text and replies, and all UI text or user-facing strings. Use a
  short sentence, a colon or a comma instead. Replace one on any line you touch.
- **Minimum viable change.** The smallest diff that fully fixes the problem: no
  drive-by refactors, renames, reformatting of untouched lines, or dependency
  upgrades folded into unrelated work. Re-read the final diff and confirm every
  touched line is required and nothing else changed.
- **DRY.** Shared logic gets one authoritative home, and nothing re-implements
  it. If you find yourself copying a block from a sibling function, factor it
  instead.
- **Deslop as you go.** Code you touch ends up cleaner than you found it where
  slop is in reach: duplicated logic factored, unbounded writes bounded, dead
  state removed, twin branches merged. Remove unimplemented stubs and dead code
  before calling the change done. Do not deslop code you are not otherwise
  touching; that is churn, not cleanliness.
- **Simplicity and maintainability.** The simplest correct code; obvious beats
  clever; write what the project's maintainers would have written. Comments
  explain why, not what. Choose solutions that stay workable so later features
  are easy to add.
- **Guide durability.** This guide holds durable rules and pointers, not
  volatile state: no test counts, current coverage figures, version or date
  stamps, churn statistics, growing suite or target inventories, or planned
  work. Point to the file that owns the current value. Keep a numeric constant
  only when it encodes a frozen contract, and name its authoritative source.
- **Honesty about validation.** Do not claim hardware validation unless it was
  run against real hardware. State what is simulator-verified and what remains
  empirical.

## Start here: docs & code map

1. Read `README.md` and `DEVELOPMENT.md` for the current implementation state,
   compatibility target and known limitations. `SECURITY.md` documents the
   backup format, and `CHANGELOG.md` records user-visible changes.
2. Check `git status` before editing and leave unrelated work alone.
3. Inspect the relevant package code and reference implementation before
   changing protocol behavior.
4. Persisted data is at the first released baseline (see `CHANGELOG.md`). Any
   incompatible storage or configuration change must include a migration from
   the previous released layout and tests with old-format fixtures; never
   silently discard user data. See *Compatibility & frozen contracts*.

**Repository layout:**

- `packages/mesh_protocol/`: pure-Dart protocol constants, codecs, identity,
  crypto, packet models and builders, and frame codec.
- `packages/companion_server/`: app-facing TCP listener, serial frame parsing,
  command dispatch and asynchronous push frames.
- `packages/mesh_node/`: node state and companion logic, driven by `RadioLink`.
- `packages/device_link/`: pure-Dart `RadioLink` SPI, TCP device client, fake
  device/radio bus for tests.
- `packages/test_support/`: dev-only framed TCP client, stream queue and fake
  scheduler shared by package, app and hardware tests.
- `app/`: Flutter UI, secure identity storage, BLE NUS transport and app
  orchestration. Shared UI building blocks live in `app/lib/widgets/`.
- `app/integration_test/`: hardware-in-the-loop validation, not part of the
  default gate. See its `README.md` for required defines.
- `packages/*/tool/`: headless and hardware-in-the-loop debugging tools.
- `scripts/check.sh`: full analysis and test gate. `scripts/coverage.sh` adds
  the coverage gate. `scripts/check_store_assets.sh` validates branding and
  store image assets.

Keep protocol/core packages free of Flutter or Android imports. Platform code
belongs in `app/`.

The authoritative wire references are `MeshCore/docs/companion_protocol.md` and
the pinned stock firmware in `MeshCore/examples/companion_radio/`.

## Current state & next milestone

The current virtual-companion handoff is implemented; `DEVELOPMENT.md` owns the
task inventory. It covers strict framing, virtual routing, capabilities and
state, persistence and quota, battery/storage, validated identity import and
export, allowlisted CLI, lifecycle, app-only reset, permission-controlled remote
CLI, telemetry and raw/control endpoints. The pure-Dart simulator drives a
hardware-free full-stack TCP test; the external hardware matrix remains
pending. The Android background-execution shape is still the main-isolate
foreground-service design, and background/Doze survival has not been
hardware-validated.

In-app backup/restore writes one passphrase-encrypted `.mcbackup` containing the
identity catalog, every identity key, per-identity node state, the saved session
and network connection history. It is the user-facing backup path; see
`SECURITY.md` for the format and restore/rollback behavior.

Signed pre-Play builds are published as GitHub Releases: release APKs use the
app signing key (the key Play will use) and the AAB uses the upload key. Testers
must use release APKs, not debug builds, so their data survives the move to
Play.

Multi-identity management is implemented: all catalog identities run live on one
shared radio, the active identity is served over the companion endpoint, and
outbound packets are mirrored in-process to the other live identities after the
RF send. Per-identity keys live in `meshcore_identity_v2/<id>` secure slots and
state in `<support>/identities/<id>/node_state.json`. Every schema change from
the first released baseline must migrate existing data. The attached radio's own
companion identity cannot be messaged through the virtual stack, and unicasts
to it are rejected.

Do not claim hardware validation unless it was run against real hardware. BLE,
multi-identity radio behavior and background execution are currently not
hardware-validated.

## Parity & intentional differences

The virtual companion must be indistinguishable from a stock MeshCore companion
on the wire. Match `MeshCore/docs/companion_protocol.md` and the pinned stock
firmware for command lengths, response codes, frame layouts, limits and routing
semantics. If stock firmware rejects, clamps or ignores something,
MeshChameleon should do the same. Virtual-only behavior (multi-identity,
telemetry/CLI extensions, app-only reset) must be explicit and documented, never
an accidental protocol divergence.

### Known intentional differences

- Self telemetry returns virtual battery voltage (and location when permitted)
  but does not synthesize MCU temperature or environment sensors. Feeding
  Android device sensors into the LPP response is a future enhancement; stock
  firmware reports board sensors.
- `CMD_SET_RADIO_PARAMS` without the optional client-repeat byte preserves the
  physical radio's current repeat setting. Stock firmware defaults repeat off
  when the byte is omitted; this affects only pre-v9 clients.
- `CMD_SET_DEVICE_PIN` and `CMD_FACTORY_RESET` are disabled: the proxy never
  changes the physical radio's PIN or wipes its storage. Both reply
  `RESP_CODE_DISABLED`; virtual reset is available from the app instead.
- Duplicate direct text is acknowledged again but queued only once. Stock drops
  the duplicate at the mesh layer without an ACK; re-ACKing keeps client
  retries confirmable over lossy links.
- `CMD_SET_ADVERT_NAME` requires a non-empty printable UTF-8 name and cuts
  overlong input on a code-point boundary; stock stores arbitrary bytes.
- `STATS_TYPE_CORE` `queue_len` reports the offline message queue length (not
  stock's outbound packet queue), and `errors` reports virtual RX errors (not
  the firmware error flags). Treat these as virtual diagnostics.
- Stock sends direct text, control data, raw data and traces directly over the
  radio. The virtual companion wraps them in `SEND_RAW_PACKET`, whose frame is
  limited by the pinned firmware. Oversized packets are rejected with
  `ERR_CODE_TABLE_FULL` before transmission. For a direct/flood message this
  gives a text ceiling below stock's protocol limit; a long route path reduces
  it further. Group text has a separate budget because the plaintext is
  `timestamp | flags | "<name>: <message>"`. `DEVELOPMENT.md` and the stock
  firmware own the current numbers.

## Compatibility & frozen contracts

### Persisted data

Persisted data starts at the first released baseline (`CHANGELOG.md`). An
incompatible storage or configuration change must include a migration from the
previous released layout and tests with old-format fixtures; never silently
discard user data. This covers the `.mcbackup` file, identity slots in
`meshcore_identity_v2/<id>`, per-identity `node_state.json`, the saved session
and network connection history. Restore and rollback behavior lives in
`SECURITY.md`. Keep migration code only while old data exists in the field, then
remove it in one excision.

### Observable wire surface

Accepted command lengths, response codes, frame layouts, limits and routing
semantics are compatibility. Reply strings and status fields are observable
API: changing them breaks clients even when the protocol still parses. Virtual
extensions must be explicit in `README.md` and `DEVELOPMENT.md`; they must never
appear as an accidental divergence.

### Frozen terminology

The companion transport is the format, not a draft awaiting a successor. Do not
introduce "wire v2" or similar naming in docs or comments, and do not rename the
existing command and push-code vocabulary.

## Principle of least surprise

The virtual companion behaves as a stock companion would: if stock rejects,
clamps or ignores something, do the same. Virtual-only behavior is explicit and
documented, never an accident. CLI and protocol semantics should read like the
concept: accepted forms are obvious, errors say what was wrong and what is
accepted, and replies stay stable because humans and companion tools parse
them. Do not make a command silently more permissive than stock, and do not
change a reply format without treating it as a breaking decision.

## Domain rules

### Protocol constraints and known gotchas

- TCP companion frames are `'<'` (0x3C) plus uint16 LE length plus payload
  inbound and `'>'` (0x3E) plus uint16 LE length plus payload outbound. The
  pinned firmware's `MAX_FRAME_SIZE` limits payload bytes; the TCP header is
  additional. The server accepts only `'<'` and the TCP device link accepts
  only `'>'`. BLE NUS carries a raw payload per write/notify without the TCP
  header, with the same limit. Group-data TX over a stock companion has a
  smaller application limit because it is wrapped in `SEND_RAW_PACKET`; a long
  route path reduces it further. `MeshCore/docs/companion_protocol.md` and the
  pinned firmware own the current numbers.
- `SELF_INFO` and `CMD_SET_RADIO_PARAMS` frequency fields are in **kHz** on the
  wire, while bandwidth is in **Hz**. `RadioParams.frequencyHz` is normalized to
  Hz internally; convert only at protocol boundaries.
- `CMD_DEVICE_QUERY` reports `max_contacts / 2` in one byte. The server must
  clamp its reported contacts.
- `app_target_ver >= 3` selects the V3 direct/channel message response layout.
  Preserve the value sent by the client in `DEVICE_QUERY`. `APP_START` bytes 1
  through 7 are reserved and must not override it.
- `PUSH_CODE_LOG_RX_DATA (0x88)` is `[code][snr*4][rssi][raw on-air packet]`.
  Only the raw packet should be delivered to `MeshNode.process` logic.
- The device identity is not the proxy identity. Do not expose it in
  `SELF_INFO` or use its high-level contact/message stack.
- Android BLE display names: `BluetoothDevice.platformName` can be a stale
  MAC-derived GAP cache. Prefer `ScanResult.advertisementData.advName` and use
  `platformName` only as fallback.
- Never log private or expanded identity key material. The private identity is
  stored through `flutter_secure_storage`; app UI reveal is an explicit user
  action, while the local companion protocol also exposes explicit export and
  import commands (the endpoint is trusted-network/plaintext).
- Firmware raw TX and path preservation, direct-route delivery and Android
  background behavior remain empirical risks: keep their tests and spike
  outcomes documented and avoid presenting assumptions as verified facts.

### UI/UX consistency

Keep the same glyphs, labels, phrasing and formatting for the same idea on every
screen. Shared building blocks live in `app/lib/widgets/`; add a shared widget
there instead of duplicating a surface in a screen. Design for the principle of
least surprise: an operator who has never read the docs should be able to
predict what each control does. Follow familiar platform conventions, favor
ease of use and visual scanning over cleverness, and keep copy plain and
user-centric with jargon only where it is accounted for. Do not use em dashes
in UI text. The current screen set lives in `README.md`, not here.

### Hardware-in-the-loop tooling

`app/integration_test/` and `packages/*/tool/` are hardware-in-the-loop and are
not part of the default gate. See `app/integration_test/README.md` for required
defines. Keep simulator tests hardware-free so the default gate stays cheap.

### Shared Flutter app conventions

- Keep protocol/core packages free of Flutter or platform imports; platform
  code belongs in `app/`.
- Widget and package tests must not touch platform plugins or the network. Use
  fakes and a populated `AppState` where a screen needs state.
- New behavior needs tests before handoff, and every bug fix needs a test that
  reproduces it and passes with the fix.
- Do not upgrade dependencies as drive-by work.

## Verification

Flutter stable / Dart are expected on `PATH`.

- Run `./scripts/check.sh` from the repo root, then the full script before
  handing off changes. `DART` and `FLUTTER` override the executables if needed.
  It runs `dart analyze` and `dart test` for each pure-Dart package, then
  `flutter analyze` and `flutter test` for the app. For narrow iteration, run
  the relevant package checks first.
- `check.sh --no-tests` runs format and analysis only; CI pairs it with
  `./scripts/coverage.sh`, which runs the same tests once with instrumentation.
- `coverage_baseline.json` is the coverage gate. Aim for at least 80% line
  coverage per source file and do not lower an existing file's coverage.
  Regenerate the baseline with `./scripts/coverage.sh --write-baseline` only
  after landing real coverage gains. Do not record current coverage numbers in
  this guide.
- Every behavior change ships tests in the same commit, and every bug fix ships
  a reproducing test. Pure refactors keep the suites green unchanged: the
  suites are the safety net that proves no behavior slipped.
- Guide screenshots live in `docs/screenshots/`. Validate branding and store
  image assets with `./scripts/check_store_assets.sh`. Branding assets are
  always checked; if `docs/store/` exists its Play assets are checked too. Pass
  `--require-store` to fail when that directory is missing, but only once the
  store listing assets are committed.
- Keep the app-only reset permission-controlled and the simulator tests
  hardware-free. Report what is simulator-verified separately from what needs
  hardware.

## Change & git discipline

- Keep changes focused and match surrounding Dart/Flutter style. Do not change
  the reference repos or upgrade dependencies as drive-by work.
- Add regression tests for protocol behavior and keep the simulator tests
  hardware-free. Update `ATTRIBUTION.md` when adapting additional external
  code.
- Update `README.md` and `DEVELOPMENT.md` when behavior or compatibility
  changes, `CHANGELOG.md` for every user-visible change, and `SECURITY.md` when
  the backup format changes, in the same commit.
- Every change must update or add tests so the touched code stays reasonably
  covered (see *Verification*). New behavior needs tests before handoff.
- Do not create a GitHub issue, PR, release, or publish artifacts without
  Jason's explicit request. Pushing code to the personal repo is allowed only
  when Jason explicitly requests it.
- Make commits only when requested or when Jason has clearly asked for a
  commit. Never bundle unrelated cleanup with an implementation commit.

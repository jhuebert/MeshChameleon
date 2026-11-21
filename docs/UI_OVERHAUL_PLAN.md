# MeshChameleon UX/UI overhaul

**Revised 2026-11-11. Status: implementation brief, with a visual-review gate
before the full rollout.** This replaces the earlier visual-refresh plan.
Updating this document does not authorize implementing or releasing the app.

**Visual review update:** Jason requested a cleaner, denser presentation: remove
the About source section and build-script explanation, remove the Home setup
help and the waiting-recovery paragraph, and replace the endpoint's text button
with an accessible copy icon. Use a slightly darker background and explore a
less yellow-green accent. A further review removed the radio activity
explanatory text and requested brief Settings descriptions without an endpoint
security note. These decisions supersede the corresponding details below;
endpoint exposure remains documented in `SECURITY.md` and project legal
notices remain required.

The synthetic Flutter render fixtures were reviewed with Jason, who requested
the changes above and then asked to continue. Android emulator/device visuals,
TalkBack, display scaling, BLE, RF, and background survival were not validated
on 2026-11-11 and remain pending.

Read with `AGENTS.md`, `README.md`, `DEVELOPMENT.md`, `docs/USER_GUIDE.md`, and
`SECURITY.md`. The review covered the current Flutter screens, app-facing
state, relevant controllers and radio-observation code, tests, and checked-in
screenshots. The screenshots predate parts of the current UI; source code is
the implementation baseline. No emulator, TalkBack, or real-hardware validation
was performed for this planning revision.

## 1. Product direction and decisions

MeshChameleon is a **companion control panel**, not a chat app and not primarily
a radio instrument panel. Its interface should answer, in order:

1. Which phone-held identity will my MeshCore app use?
2. Is the radio connected, and is the proxy serving the client?
3. What should I do next if it is not working?
4. What activity and resources can I inspect when I need more detail?

The goal is a recognizably branded, calm Android utility with better hierarchy
and trustworthy feedback—not the current cards with more decoration.

### Confirmed with Jason in this revision

| Question | Answer and consequence |
|---|---|
| Audience | **Mixed experience.** Fast everyday operation, with contextual explanations for people new to a virtual companion. |
| Home density | **Progressive detail.** Identity and connection controls first; compact activity summary with expandable details. The previously selected metrics remain accessible from home. |
| Scope | **Include UI-only UX fixes.** Copying the client endpoint, actionable failures, clearer GPS scope, and inline validation are in scope. Protocol, persistence, connection, and activation behavior stay intact. |
| Earlier “locked” decisions | **Revisit if warranted.** They are no longer immutable constraints. Retained choices below have a product rationale, not merely precedent. |

### Foundations retained after review

- **One Settings gear in the home app bar.** There is one primary control
  surface, not enough peer destinations to justify bottom navigation or a
  drawer. Contextual diagnostic links are still allowed near failures.
- **Static green brand theme, system typography, system light/dark selection.**
  Reuse the existing artwork. Dark is the showcase, not a forced preference;
  light mode gets equal functional and accessibility review.
- **Quick-switch identity sheet**, backed by the existing Identities screen for
  management. Switching is frequent; destructive management is not.
- **Separate About and Information.** About describes the product and build;
  Information remains the live diagnostics destination.
- **Phone-first, width-constrained single-column navigation.** Preserve Linux
  usability for development; no tablet navigation redesign in this round.

These are project choices, not universal Material requirements. Navigation
should follow the actual destinations and tasks; dynamic color could support
semantic statuses too, but is unnecessary for this brand-focused round.

## 2. What needs fixing, and why

| Finding | Evidence in the current app / earlier plan | Design response |
|---|---|---|
| Repeated state without a clear hierarchy | `main.dart` repeats identity/device/proxy state in `_StatusCard` and the controls below it. The earlier plan replaces this with six substantial home panels. | One identity area, one connection group, one progressively disclosed activity area. Each fact has a primary home. |
| The primary control gets buried | The earlier layout puts the proxy switch after signal, client, queue, and battery panels. | Put the proxy next to the radio connection, before secondary metrics. |
| Setup stops short of the client handoff | Home shows a port field, but not a copyable `127.0.0.1:<port>` or an explanation of the two separate connections. | Show the client endpoint with Copy, and a short “How to connect” explanation. |
| A single “connected” signal can mislead | Radio link, live identity runtime, proxy listener, and TCP client are distinct states. Reconnecting can leave the listener and client up. | Show the axes separately; use the state matrix in §6. |
| Empty, loading, and broken are conflated on home | `HomeScreen` uses `activeIdentity == null` without checking `identitiesLoaded` or `identityDatabaseError`; Identities already handles those cases. | Dedicated loading and recovery presentations. Never suggest creating a replacement identity for a database failure. |
| Small UX failures are preserved as if they were contracts | Proxy start errors are logged; the earlier plan assumes existing completion snackbars. Invalid port input is reset. GPS setters return a boolean the current UI ignores. | Truthful pending/error feedback, preserved form drafts, and explicit save outcomes. Tests protect behavior, not incidental widget structure. |
| GPS scope is inconsistent | `AppState.phoneGpsRequested` and the effective interval summarize the shared location service, but setters write to the active node. | Separate active-identity preferences from shared phone sampling status. This is a required correctness fix, not a move-verbatim exercise. |
| Statistics are easy to misread | Queue = received messages awaiting client sync; RSSI/SNR = last raw mesh reception; link counters survive reconnects and radio changes. | Label scope and units accurately. Do not imply outgoing backlog, unread messages, Bluetooth strength, or current-radio session totals. |
| Proposed telemetry includes nonexistent data | `DiagnosticsSnapshot.generatedAt` is snapshot creation time, not last packet time. `LinkMetrics` currently has no RX timestamp. | Add a passive timestamp if showing reception age; never fabricate it from snapshot refresh time. |
| Battery ownership/freshness are wrong in the old implementation sketch | `SharedRadioHub` already retains the physical reading. Node battery freshness is 10 s, periodic refresh is 60 s; the client-facing storage is virtual. | Expose shared physical observations without moving physical storage into each virtual node or reusing the wrong stale flag. |
| Visual polish is over-specified before it is validated | Numerous exact colors, tiny uppercase labels, many new one-use wrappers, pulsing dots, and double haptics are prescribed as “implementation-ready.” | Establish a small theme, build representative states, review actual renders, then propagate the approved language. |

## 3. Scope and safety boundaries

### Required in this overhaul

- Home hierarchy and state-dependent guidance; Settings and About destinations.
- Quick identity switching with clear consequences and reliable async handling.
- Client status and a copyable loopback endpoint.
- Queue, TX/RX, last mesh RSSI/SNR, physical radio voltage and storage, using
  progressive disclosure rather than a separate large card for each metric.
- Consistent theme and screen treatments, accessible layouts, form/error polish.
- Correct presentation of per-identity GPS settings versus shared sampling.
- Tests, updated navigation documentation, and representative screenshots.

### Explicitly out of scope

- Companion protocol, framing, firmware parity, command semantics, RF behavior,
  message queues, or radio configuration changes.
- Persistence schemas, backup format, identity key operations, new offline
  settings-editing behavior, or migrations. Storage stays at the released
  baseline; any subsequently proposed incompatible change needs its own scope,
  migration, and old-format fixtures.
- Listener binding/authentication changes, new permissions, background engine
  redesign, boot resume, client auto-reconnect, or automatic proxy start on
  ordinary manual radio connection.
- Chat, unread counts, charts/history, cloud features, analytics, widgets,
  notification redesign, new transports, or iOS work.
- A mandatory onboarding wizard, persisted tutorial-dismissal flags, a theme
  preference, new fonts, new branding art, or new navigation/state frameworks.
- Dependency/toolchain upgrades, new packages, version bumps, commits, PRs,
  publication, or releases without a separate request.

Small read-only presentation additions are allowed in `app/` and, for shared
radio observations, `packages/device_link/`. **No `mesh_node` change is expected**
for the proposed physical battery display. Keep `mesh_protocol` and
`companion_server` unchanged. Core observation code stays pure Dart, without
Flutter/Android imports. Reference repositories remain read-only.

Do not silently drop a selected metric or ship a permanent placeholder because
plumbing was inconvenient. Missing runtime data must degrade honestly; deferring
an entire feature requires an explicit scope decision recorded here.

## 4. Information architecture

```text
Home
├─ Active identity → Switch identity sheet
│  └─ Manage identities → Identities (existing)
├─ Device link → Connect device (existing)
├─ Proxy server switch + MeshCore app status + Copy address
│  └─ How to connect → short setup sheet
├─ Radio activity → expand details in place
│  └─ Information → live diagnostics (existing)
└─ Settings
   ├─ Connection & background
   │  ├─ Proxy server port → edit dialog
   │  ├─ Resume on launch
   │  └─ Battery optimization (Android)
   ├─ Phone telemetry
   │  ├─ Active identity's location preferences
   │  └─ Shared phone/permission/sampling status
   ├─ Data
   │  ├─ Identities → management
   │  └─ Backup & restore (existing)
   └─ Support
      ├─ Information — live diagnostics
      ├─ Log
      └─ About MeshChameleon
         └─ Open-source licenses (Flutter LicensePage)
```

Keep existing `Navigator`/`MaterialPageRoute` patterns. No routing package is
needed. Back returns to the invoking screen; Back from a sheet dismisses the
sheet. Back from Settings does not save an unsubmitted edit or affect a session.
Preserve Connect's distinction between abandoning an initial connection and
leaving an established session's recovery running.

Settings is the permanent support entry, not the only way to reach a log
or diagnostic. A nearby “View log” action after a failure is more useful than
making a user remember a navigation path.

## 5. Home: identity, connections, then activity

### Hierarchy and space budget

Use a top-aligned, scrollable column. Target at most **three major surfaces** in
the normal state: identity, connections, activity. A conditional warning is not
another permanent dashboard card.

At **360 × 800 logical pixels, default text scale**, the active identity, device
state/action, and proxy switch must be visible without scrolling. Client status
and address should also fit in the normal idle/connected fixtures. At 320 px,
in landscape/split-screen, or with larger text, scrolling is acceptable; hiding
or clipping a control is not. Measure this on the prototype rather than relying
on an ASCII drawing's apparent height.

Schematic connected state; exact dimensions are deliberately not frozen:

```text
[mark] MeshChameleon                              Settings

Active identity
┌──────────────────────────────────────────────────────┐
│ [avatar] Trail Crew                         Switch ▾ │
│          #5D11B88B · Live                             │
│ 4 contacts · 2 channels · 2 waiting to sync            │
└──────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────┐
│ Device link                                      ›   │
│ Bluetooth · MeshCore-nc3 · Connected     Disconnect   │
│ ──────────────────────────────────────────────────── │
│ Proxy server                                  [on]   │
│ Listening on port 5000                               │
│ ──────────────────────────────────────────────────── │
│ MeshCore app                              Connected   │
│ On this phone: 127.0.0.1:5000                 [Copy]   │
└──────────────────────────────────────────────────────┘

Radio activity                                         ▾
┌──────────────────────────────────────────────────────┐
│ TX 128          RX 342          Radio 3.91 V          │
│ Packet totals since app opened                       │
│ [expand: last mesh RX, SNR, sample age, radio storage] │
└──────────────────────────────────────────────────────┘
```

### 5.1 Identity area

- Name and public-key prefix identify the **phone-held** identity; do not show
  the physical companion's identity. An explicit `Switch` affordance opens the
  quick-switch sheet. The name area can be part of the same hit target.
- Give the name room before spending width on an avatar or status decoration.
  Allow two lines when necessary; make the full name available in the sheet and
  accessibility label. Do not solve overflow by reducing user text scaling.
- Show contact/channel counts as secondary metadata, not three oversized stat
  columns. Show the active identity's queue **once**, as `2 waiting to sync` or
  `No messages waiting to sync`. Detail explains direct/channel counts and that
  these are not unread or unsent messages.
- Other identities' queues are visible in the switch sheet. A nonzero aggregate
  such as `4 waiting on other identities` may accompany the identity summary;
  it must be clearly distinct from the active identity's count.
- Keep total/enabled/running identity counts available in the sheet. They do not
  require another permanent home line if the compact layout becomes crowded.
- Distinguish selected identity from runtime state. An active identity can be
  offline; “Inactive” is not the correct status for that case. See §7.
- Database, loading, genuine-empty, and individual-unavailable states follow §6.

### 5.2 Connection group

**Device link**

- Keep this navigation label for continuity, with the radio name and transport
  as supporting information. Use `deviceTargetIcon` and the saved target kind;
  an idle TCP session should not misleadingly become a Bluetooth icon.
- Idle: a clear connect affordance leads to Connect. Connected: show
  `Disconnect`. Connecting/reconnecting/waiting: show `Cancel`. Disconnecting:
  show progress and no new conflicting operation.
- The navigation target and Disconnect/Cancel are separate, non-overlapping
  controls. Do not nest a small action inside an indistinguishable whole-card
  action. Cancellation must remain usable during a connection's busy state.
- Recovery details belong beside this status, not as a loose paragraph far from
  the control. Do not promise a proxy restart when the user had it stopped.

**Proxy server**

- Keep a standard accessible switch with a full-row label. Its value reflects
  **actual listener state**, not an optimistic local boolean. Preserve the
  controller's serialization and current eligibility rules; a running listener
  can still be stopped during reconnection when the existing guards allow it.
- Add a local pending affordance while a user-initiated start/stop awaits
  completion; suppress duplicate submissions. Do not introduce a second
  connection/proxy state machine in the widget.
- `Listening on port <port>` and `Stopped` remain useful primary status copy.
  Explain a disabled switch: connect a radio, wait for the current operation,
  or resolve the identity problem, as appropriate.
- Failed start leaves the switch truthful and shows a persistent local failure
  message with a recovery action. A generic error is acceptable if the API
  cannot distinguish the cause; do not invent “port in use” or parse logs for
  control flow. A canceled/interrupted operation is not a spurious start error.
- No new confirmation for ordinary start/stop, no mandatory success snackbar,
  and no success haptic just because a `Future<void>` completed.

**MeshCore app and endpoint**

- Status distinguishes `Server stopped`, `Waiting for app`, and `Connected`.
  Waiting for a client is normal, not an amber/red fault.
- Show `127.0.0.1:<configured port>` with an explicit, accessible Copy action.
  Copy copies just the endpoint, not a diagnostics report. It works when stopped
  too, with status making clear that the server is not listening.
- A connected client's address is optional secondary detail; label it as the
  **client address**, not the server endpoint. Long/IPv6 addresses must wrap.
  Session duration belongs in expanded details/Information, not another timer
  competing for attention on home.
- When a client is absent, `How to connect` explains: connect the radio to
  MeshChameleon; start the proxy; configure a TCP/network companion in the
  client using this endpoint. MeshChameleon is not the messaging app.
- Setup help shows **Host** (`127.0.0.1`) and **Port** separately, with individual
  copy actions for clients that use separate fields. Label the home action
  `Copy endpoint` if it copies `host:port`; never instruct users to paste that
  combined string into a host-only field.
- The same-phone path is primary. For another device, explain using the phone's
  LAN address, not `127.0.0.1`. Do not guess a routable phone address or add
  network-discovery permissions in this overhaul.
- Include a concise security note in setup help and Settings: the listener is
  **plaintext, unauthenticated, and reachable on local-network interfaces**.
  It is not loopback-only just because the displayed default is loopback.

### 5.3 Activity: useful summary, optional depth

- Collapsed: TX/RX packet totals and physical radio voltage, with an explicit
  `Radio activity` expansion affordance. This area always follows the controls.
- Expanded: last mesh RSSI/SNR, actual reception age if available, battery
  sample age, and **physical radio storage used/total**. Add a contextual
  Information link for full diagnostics. At large text scale use stacked rows,
  not a forced three-column grid.
- Queue detail belongs to identity scope (§5.1/§7), not an unrelated radio
  battery row. Do not show the same queue total in two home panels.
- Physical link totals cover **all identities since this app run began**,
  including reconnects and radio changes. They are not per-identity totals or
  necessarily the current radio's session totals. TX is a successful raw-send
  operation, not proof of on-air delivery or an ACK.
- RSSI/SNR describe the **last received mesh packet**. They do not measure BLE,
  Wi-Fi, all neighbors, or general mesh health. Use numeric values and units,
  not invented “good signal” thresholds or cellular coverage bars.
- No packet yet is different from 0 dBm; no battery sample is different from
  0 V. Display `Not received yet` / `Unavailable` / `—` with context, not
  fabricated zeros or indefinite loading spinners.
- On disconnect, show `No radio connected`. Historical app-run counts can stay
  available in details, clearly labeled; old samples must not look current.
  Reset current-radio signal/health provenance when choosing a different radio.
- Simulation remains available and is visibly labeled **Simulated · no radio
  traffic** on home as well as Connect. Fake voltage/activity must not resemble
  a real connected radio without that qualification.
- Expansion is transient UI state, retained while navigating within this app
  session where convenient. No new persisted preference is needed.

## 6. State and recovery contract

Use existing state as truth. Do not collapse these cases into one green dot.
Only the most relevant next step should receive primary emphasis.

| Situation | What the user sees | Available action / invariant |
|---|---|---|
| Catalog loading | `Loading identities…` in the identity area; no fake empty state. | Settings/support stay reachable. Do not offer creation as a loading fallback. |
| Identity database error | `Identity database unavailable`, an explanation that existing data was kept, and retry/support/restore paths. | No replacement identity, automatic reset, “clear storage” advice, or destructive recovery shortcut. |
| Loaded, genuinely empty catalog | A genuine empty-state explanation and creation entry. | Fresh installation normally creates a default identity; this is not the normal first-launch onboarding screen. |
| Active identity unavailable | Preserve its name/prefix, show the reason, and offer identity management or another valid identity. | No green “Live” claim; cannot start the proxy against an unavailable node. |
| Radio idle | `Not connected`; proxy stopped with a connect-first reason. | Connect opens the existing transport selection. Missing GPS permission does not block core operation. |
| Initial connection | `Connecting…`, target label, scoped progress. | Cancel remains enabled. Back from Connect preserves existing initial-attach cancellation semantics. |
| Radio connected, proxy stopped | Radio connected; identities may already be running/receiving; `Proxy server: Stopped`. | Starting the proxy is the next step. Do not imply stopping the proxy also stops all identity runtimes. |
| Proxy running, no client | `Listening on port …`; `Waiting for app`; endpoint and setup help. | This is ready for a client, not proof that mesh delivery works. |
| Proxy and client connected | Show both states and the active identity. | Copy endpoint, switch identity, stop proxy, or disconnect radio remain distinct actions. |
| Brief link loss | `Reconnecting…` even if listener/client remain connected. | Keep truthful proxy state; Cancel ends recovery. Do not show a healthy end-to-end connection just because TCP is still open. |
| Parked recovery | `Waiting for <radio>`; proxy stopped; explain that previous proxy intent is restored when the radio returns. | Cancel stops waiting. Reconnect the client if necessary after recovery. Never promise that every client reconnects automatically. |
| Disconnecting | `Disconnecting…` and scoped progress. | No duplicate disconnect/connect submission; do not turn a temporary transition into an error. |
| Start/connect/save failure | Local explanation beside the affected control and a retry/correction/log path. | Retain the last valid state and form draft. No success indication inferred from a swallowed exception. |
| Battery optimization enabled | Conditional `Background link may be interrupted` advice during an active/recovering session. | Opens the Android setting or its Settings section. Not a permanent alarm in idle; “Unrestricted” is not a survival guarantee. |
| Sample absent/old | Unknown or last-known value with age/provenance. | No new device request from a rebuild, expansion, or UI refresh timer. |

Busy indicators belong near the operation. A global busy state can disable
conflicting mutations, but must not trap navigation, Copy, or recovery Cancel.
Use text for actionable states, not an unexplained progress strip at the bottom.

## 7. Identity switching and management

### Quick-switch sheet

- Title `Switch identity`; active selection is marked once with an accessible
  check/selected state. List every identity with name, prefix, availability, and
  queued messages waiting to sync. Contact/channel detail can remain secondary
  to selection rather than making every row a full management card.
- Keep **selection** (`Active`) separate from **availability**: running/live,
  offline, reconnecting, disabled, or unavailable. An enabled identity can be
  selected offline when `canActivate` allows it; do not add a live-only gate.
- Use `canActivate`, `active`, and `app.busy` consistently with the management
  screen and controller. Disabled/unavailable rows expose a readable reason;
  they are not silently dead buttons. Enabling remains a management action.
- Explain once in the sheet: `Switching disconnects the current MeshCore app.
  Reconnect it if it does not reconnect automatically.` No confirmation dialog
  on every normal switch. Other enabled runtimes are not stopped by selection.
- On tap, re-read eligibility, await activation, and prevent duplicate requests.
  Close on success only. On failure, keep the sheet usable and show
  `Could not activate <name>` without losing the current selection.
- Handle dismissal during the await: never pop the underlying Home or show a
  snackbar against a disposed sheet. Switching need not be canceled merely
  because its presentation was dismissed.
- `Manage identities` is always discoverable, including with only one identity.
  Dismiss the sheet before opening management, using a result/callback to the
  parent route. Do not push management above a still-open sheet and then rely
  on an ambiguous `Navigator.pop` after activation.
- Use a scrollable sheet with safe-area/keyboard insets and a reachable manage
  action. At large text scale or with many identities, scrolling beats an
  arbitrary fixed height. Maintain stable row keys by identity id.

### Identities screen

Adopt the same name/prefix/status language and optional avatar. Keep create,
enable/disable, clear-local-data, and delete rules unchanged. Retain UTF-8 byte
validation, active/last-identity protections, destructive confirmations, and
the distinction between clearing data and deleting a key. Existing loading and
database-error paths must not regress.

Explain the client disconnect consequence here too. Preserve disabled-action
reasons and queue meaning. Cosmetic changes must not add per-identity key
reveal/export controls, which the current UI intentionally lacks.

## 8. Settings: compact overview, explicit scope

Use grouped lists with sentence-case headings. Do not reproduce the old home
as a long series of individually decorated cards and always-open text fields.

### Connection & background

| Item | Interaction and copy |
|---|---|
| Proxy server port | Overview row shows the current value. Tap opens a small edit dialog with a labeled numeric field, Cancel, and explicit Save. Accept only 1–65535; show validation inline and retain invalid input for correction. Save only while stopped and not busy; if eligibility changes while editing, explain it instead of applying silently. Keep a stable `Save port` accessible label/tooltip for automation. |
| Resume on launch | Existing boolean and setter. Explain reconnecting the last radio and starting the proxy when the app opens, not after a phone reboot. With no saved target, explain that a successful connection is needed to remember a session; do not invent a target or a new persistence rule. |
| Battery optimization | Android-only status and explicit system-settings action. Checking/unknown is not Unrestricted. Refresh initially and on foreground return. Use cautious copy: unrestricted reduces one source of interruption; Android/OEM restrictions can still interfere. Do not request an exemption permission or claim Doze survival has been validated. |

The port edit changes configuration only; it never stops/restarts a running
listener on behalf of the user. Preserve the existing best-effort persistence
contract rather than claiming a durable save that the API cannot confirm.

### Phone telemetry

This section must make its two scopes explicit:

1. **For `<active identity name> · #<prefix>`**: its own `gps` preference and
   configured `gps_interval`. A switch labeled `Use phone GPS` (or equally
   clear scoped copy) is preferable to an unqualified global sharing switch.
2. **Shared phone status**: phone battery, Android location permission, whether
   any identity requests GPS, effective shared sampling cadence, fix age, and
   the last sampling error. These are read-only status, not this identity's
   preferences.

Keep the overview concise; advanced interval/status detail may expand in place.
Requirements:

- Read the displayed editable preference from the **same identity the setter
  modifies**. `phoneGpsRequested` cannot be the switch's value: it means “any
  identity requested GPS.” Likewise, the fastest shared cadence cannot stand
  in for the active identity's configured interval.
- The default configured interval is 900 s. Preserve acceptance of 0–86400;
  stored `0` means an effective 1 s. Explain the special value and battery cost,
  and distinguish configured interval from actual shared sampling cadence.
- Continue requiring an available live node for editing; do not quietly add
  offline storage writes. When unavailable, explain why controls are disabled
  rather than showing a made-up `off` preference.
- Tie drafts to the identity id. If selection changes while Settings is open,
  update the scope and discard/invalidate that identity's unfinished editor
  explicitly; never submit the old draft to the newly active identity. Do not
  overwrite a focused draft on routine status refreshes.
- Await setters and handle `false` with local feedback. Permission-denied with
  GPS requested is a valid blocked state, not a successful location fix or a
  reason to silently clear the saved request.
- Keep permission requests explicit and contextual, with the existing rationale
  and Cancel path. Show system-settings recovery when appropriate. No prompts
  on launch, screen build, or background telemetry refresh; no new permission
  implementation in this round.
- Explain: GPS supplies coordinates to this identity; MeshCore telemetry
  permissions and advert-location policy still govern exposure. Turning off
  updates does **not** erase stored coordinates or guarantee that all location
  exposure stops. Do not show coordinates in logs or copied diagnostics.
- If another identity requests GPS while this identity is off, make that shared
  activity clear. Switching off one identity is not a global stop-GPS control.

### Data

- `Identities` → the management screen, showing the catalog count if useful.
- `Backup & restore` → existing flow. Supporting copy mentions **all identities
  and their keys** in one passphrase-encrypted file. No invented last-backup
  status, cloud implication, or new reminders without a data source.

### Support

- `Information` — `Live status and diagnostics`.
- `Log` — `Recent app and radio events`.
- `About MeshChameleon` — `Version and open-source licenses`.

Keep support navigation enabled when a radio or identity has failed. A short
endpoint-security explanation belongs here or in Connection & background, not
only in an external document.

## 9. Other screens and shared feedback

### About MeshChameleon (new)

- Existing brand mark, app name, and established tagline. Use a modest,
  responsive header; the long app name must fit or wrap on compact phones.
- Installed version/build prominently; build details use **existing**
  `BuildInfo.versionLabel`, `cardDetails`/`details`, `commitLabel`, and
  `buildTimeLabel`. These helpers already exist—do not add a redundant
  `buildInfoRows` mapping. Preserve ABI-adjusted Android build numbers, partial
  metadata, dirty markers, UTC times, and genuine unavailable/dev-build states.
- MIT license and copyright from the repository's legal text, plus a selectable
  source URL with an explicit Copy action. Do not style a non-launching URL as a
  working browser link. Browser launch can be a separate approved enhancement;
  no bespoke native launcher or new package is necessary for this overhaul.
- Flutter's `showLicensePage` for open-source dependencies. Verify what the
  license registry actually contains; showing that page does not automatically
  include this app's MIT text or adapted-source notices. Make existing project
  legal notices accessible too, bundling/registering them if needed. Minimal
  asset declarations are allowed for legal text, not dependency/version changes.
- No live polling, duplicate live-status cards, or requirement to add another
  Information link just to fill space. About remains useful offline.

### Information

Keep `DiagnosticsScreen`, title `Information`, diagnostic coverage, 5 s cadence,
and copy-report semantics. Build details may remain here for support even though
About also presents them. Restyle with the theme and make label/value layout
stack on narrow widths or large text; do not standardize the current fixed
128 px label column into every screen.

Report content includes addresses, names, and recent logs; explain reviewing it
before sharing near the copy workflow. Preserve existing redaction/no-private-key
and no-coordinate guarantees. Adding passive health rows is fine if implemented
and tested; it must not remove existing diagnostic facts or change wire stats.

### Connect device

- Preserve capability-gated tabs, initial tab/target selection, saved history,
  success returning home, cancellation, and parked-recovery behavior. The
  Simulated tab keeps its position and behavior in this overhaul.
- Clearly label the Network fields as the **radio's** host/port, not the proxy
  address. Keep hostnames and IPv6 support; do not narrow validation to IPv4.
- Use a clear primary scan/connect action and consistent result rows. Bluetooth
  result RSSI is explicitly Bluetooth signal, distinct from home mesh RSSI.
  Preserve advertisement-name precedence over the stale platform-name cache.
- Surface scan-start failures and a helpful no-results state. Reflect actual
  scan completion: the plugin times out after 15 s, while the current local
  `_scanning` flag does not observe that timeout. Keep returned results visible
  for selection and provide Rescan. This is a screen-state fix, not a BLE
  transport/retry redesign; test it through a minimal injectable scan seam.
- No automatic scan/permission request on opening the page. Stop scanning on
  departure/tab change as today. Keep saved-connection delete with Undo.
- Connect failure feedback stays contextual and offers the log; do not convert
  a user cancellation or ongoing recovery into a generic failure snackbar.

### Backup & restore

Apply the theme, width constraints, and readable spacing without redesigning the
security-critical workflow. Keep passphrase/confirmation validation, file-picker
cancellation, inspection before replacement, destructive scope, busy state, and
rollback messages. Dialogs remain usable with the keyboard and large text.
Restoring stops the link/proxy and replaces all local identities/data as today.

### Log, dialogs, and snackbars

- Log remains newest-first, selectable/readable monospace where appropriate,
  with Copy. No severity filters, persistent log storage, or decorative event
  timeline in this scope. Keep long lines accessible by wrapping or intentional
  scrolling; do not ellipsize away support information.
- Use inline field errors for correctable input, contextual banners for an
  unresolved operation, snackbars for brief acknowledgement/Undo, and dialogs
  for confirmations or blocking errors. Do not use a transient snackbar as the
  only explanation of an ongoing broken state.
- Destructive dialogs name the affected identity and what is lost; Cancel is
  easy to find, and red is reserved for the destructive action. Do not add
  haptics/celebration to restore, delete, or failed async operations.

## 10. Visual and interaction system

### Brand without “everything green”

Create `app/lib/theme/app_theme.dart`; split further only when useful. Use
Material 3 components and component themes rather than a custom rendering system.

| Element | Direction |
|---|---|
| Surfaces | Quiet green-neutral surfaces. Use existing `#0C1E1B` / `#06140F` artwork as dark anchors, not a demand that every card be saturated green. Light surfaces should be near-neutral and equally intentional. |
| Primary accent | Chameleon greens/lime for the principal action and selected identity. Candidate dark accent `#C2F57A` or a softened green; candidate light primary `#1F7A45`. Values are starting points, not approved role pairs. |
| Secondary accent | Restrained brand teal (`#3FE6BA` family) if a second accent earns its place. Never a claim of “good RF signal.” |
| Status | Neutral for idle/no client; green for a healthy specific state; amber for recovery/attention; error roles for failure/destruction. Pair color with text/iconography. Selection is not the same thing as connectivity. |
| Shape | A small family: roughly 16–20 dp grouped panels, standard Material controls, standard modal shapes. Do not wrap every row in another rounded container. |
| Spacing | 4/8/12/16/24/32 dp rhythm; normally 16 dp page margins and 12–16 dp between major groups. Containment and whitespace establish hierarchy, not a border around every datum. |

Derive a static `ColorScheme` baseline and tune actual roles as needed.
`ColorScheme.fromSeed` is an acceptable authoring/implementation tool; literal
hex values are not intrinsically more designed. What matters is a stable,
reviewed light/dark result, complete role coverage, and consistent usage. No
wallpaper-derived dynamic scheme in this round.

Use theme roles for components and a small semantic extension for status
foreground/container pairs if needed. Do not hardcode colors throughout screens
or lower important text contrast with arbitrary opacity. Test composed colors,
including tinted surfaces, selected rows, input states, and snackbar inverses.

### Type, layout, and affordances

- Keep platform/system fonts. Start with Material's readable type scale: about
  16 sp control/body labels, 14 sp supporting text, 20–24 sp identity emphasis.
  Do not globally shrink the app to fit more metrics. Avoid ubiquitous 11 sp
  uppercase tracked headings; sentence case is easier to scan here.
- Use tabular figures for counters/ports; monospace for logs and technical
  strings when useful. `MeshChameleon` and long identity names must wrap or
  constrain gracefully rather than overflow.
- An avatar is optional decoration, not a requirement for product quality. If
  used, take the first grapheme safely, handle empty/emoji names, and choose
  a stable deterministic tint from a small tested palette. Do not rely on
  process-dependent `String.hashCode` for a cross-run visual identity or imply
  that a tint/monogram is a security fingerprint.
- Prefer explicit affordances: chevron for navigation, expansion indicator for
  disclosure, switch for on/off, labeled action for Copy/Save. No no-op ripples.
- Start with a roughly **600 dp maximum content width**, top-centered. Apply
  consistently to Home, Settings, About, and existing forms/lists where it
  improves readability. Keep log/technical content readable and fully reachable.
  Do not vertically center an entire scrolling screen or constrain it to a
  fixed height. No new rail/two-pane layout is needed.

### Motion and haptics

Use standard Material transitions and short, optional status crossfades. No
continuous pulsing dots, bouncing counters, animated telemetry values, or
shimmer. There is no need for a tap haptic plus a completion haptic for one
switch action. Native/component feedback is the baseline; add at most a subtle
selection haptic if the prototype demonstrates value without duplication.

Respect reduced-motion settings and stop decorative animation when not visible.
Status updates must not move controls, change focus, or continuously announce
packet counts to TalkBack.

### Accessibility is an acceptance condition

- At least 48 × 48 dp touch targets, including Copy, row actions, sheet entries,
  and icon-only controls. Do not shrink Material tap targets for visual density.
- Normal text contrast ≥ 4.5:1; large text ≥ 3:1; meaningful control boundaries,
  icons, and selected-state indicators ≥ 3:1 against their adjacent background.
  Test real rendered role combinations in both themes, not every possible
  foreground/background permutation. Disabled controls still need clear reasons.
- Natural reading/focus order matches visual order: identity → radio → proxy →
  client → activity. Let standard controls provide semantics; exclude decorative
  dots/avatars and avoid duplicate spoken labels from blanket wrapper semantics.
- At 1.0×, 1.3×, and 2.0× text scaling: no lost actions, clipped errors, fixed
  card heights, forced one-line metadata, or horizontal page scrolling. At high
  scaling, stack stat cells and label/value rows; do not clamp `TextScaler`.
- Check Android display scaling, keyboard insets, gesture navigation/safe areas,
  sheet focus return, Back/Escape, and keyboard traversal on Linux. Test long
  names, prefixes, IPv6 addresses, multiline errors, and grayscale states.
- Announce meaningful user-action outcomes and state failures, not every poll.
  A status dot is decorative if adjacent text already communicates the state.

## 11. Data and architecture: observe, do not change the engine

Keep the `AppViewState` screen boundary and `FakeAppState` testing pattern.
Prefer small immutable presentation values to many unrelated nullable getters.
Names below describe responsibilities, not a mandate for a new class per line.

### 11.1 Current data truth and required additions

| Data | Current source | Required treatment |
|---|---|---|
| Active identity, counts, queues | `IdentitySummary` from `IdentityManager` | Reuse summaries; maintain their change notifications. Selection and availability stay separate. |
| Device/proxy/catalog state | `AppViewState` / existing controllers | Reuse; UI pending state only for its submitted operation. No duplicated runtime transitions. |
| Client, TX/RX, signal | `diagnosticsSnapshot()` → `CompanionMetrics` / `LinkMetrics` | Project to immutable display primitives before storing/comparing. Snapshots currently reference live mutable metrics objects. |
| Reception age | Not currently exposed | Add a passive timestamp at raw-RX observation, with source provenance; omit age until real data exists. `generatedAt` cannot substitute. |
| Physical voltage and storage | `SharedRadioHub._batteryCache` / `_batteryCachedAt` | Expose a read-only last-successful sample plus timestamp through the manager/app presentation boundary. Reads must not trigger `battery()` or alter cache expiry/coalescing. |
| Editable GPS settings | Active node's existing `getCustomVars()` / `gpsEnabled` | Expose a scoped nullable presentation value containing identity id, requested flag, and configured interval. Do not use aggregate `PhoneLocationService` values as an editor model. |
| Shared phone telemetry | Existing `phone*` getters | Keep their aggregate meaning for diagnostics/status. Do not silently redefine them to fix one switch. |
| Build rows | Existing `BuildInfo` helpers | Reuse; add only presentation and test fixture injection if needed. |

### 11.2 Physical radio health

Preferred implementation is read-only exposure of the **existing shared hub
cache**, whose detach generation already rejects late sample publication.
`IdentityManager` owns that hub; `AppState` maps it to a non-secret display value.
This keeps radio health independent of which identity is active. Do not add a
per-node capture closure that can publish a late reading outside the node's
generation guard, and do not call `getBatteryAndStorage()` for physical storage:
that intentionally returns the identity's **virtual 4 MiB partition**.

Rules and tests:

- Keep 60 s periodic reads, 10 s request-cache freshness, coalescing, and all
  existing failure/transport behavior unchanged. UI visibility must not control
  the node's telemetry service or introduce new device requests.
- Distinguish last successful sample, sample time/age, connection availability,
  and unknown/unsupported data. Cache exposure remains readable after the
  request freshness window; it must not imply a new sample was taken.
- Show voltage as voltage (for example `3.91 V`); do not infer battery percent,
  charging state, or low-battery thresholds from an unknown board/chemistry.
- Storage uses KiB despite the existing `*Kb` field names. Show used/total;
  a percentage is supplementary and only when the reading is valid and total
  is positive. Physical radio flash is not phone or identity storage.
- Prefer neutral `Updated 45s ago` to a stale warning during normal cadence.
  If a warning is needed, use a documented **UI-only** delayed-sample policy
  (initially two normal refresh intervals, 120 s), not `node.batteryStale`,
  which becomes true after 10 s. Never change protocol freshness to suit the UI.
- Clear current-source sample presentation on new target/detach/restore. A
  failed or null read does not refresh the successful sample timestamp. An old
  hub's in-flight completion cannot populate the new radio's health.
- Switching active identities on the same hub must not reset physical health
  or multiply physical sample reads. Test with multiple live identities.

For last-RX age/provenance, a small additive observation in `LinkMetrics.rawRx`
and an explicit current-link boundary are appropriate. Preserve cumulative
packet counters; do not reset them to make a “current radio” label accidentally
true. Keep existing diagnostic fields/report semantics compatible. Use injected
time in tests and guard against negative displayed ages. If necessary, track
current-source observations separately from the legacy app-run last-signal
fields so source invalidation does not rewrite diagnostic history.

### 11.3 Refresh ownership and lifecycle

- Cached packet/client counters do not emit all UI changes. Start with **one
  5 s cached-snapshot sampler while Home is the visible route and the app is
  resumed**. Read immediately on entry, foreground return, route return, and
  relevant state notifications. Client status should update by the next tick.
- Project only home data. Rebuild the client/activity/queue subtrees as needed,
  not the whole form/list on a timer. Preserve expansion, scroll, and focus.
  Do not add a timer per stat or one-second duration counters.
- Pause/cancel sampling when covered by another screen/modal, backgrounded, or
  disposed; refresh immediately on return. An offstage route staying mounted
  is not “visible.” Use a small route/lifecycle hook, tested in the app shell.
  `TickerMode` alone does not stop a `Timer`.
- Do not copy diagnostics' scroll-pause logic blindly. A localized stable-size
  metric rebuild need not stop during scrolling; measure before adding that
  extra state. No raw device I/O is permitted from the sampler.
- **Recovery rearming is separate from display polling.** Preserve
  `rearmAfterLinkLoss()` on foreground resume even when Home is covered by
  Settings. Extraction from `main.dart` must not remove or duplicate that hook.
- Moving battery-optimization UI out of Home removes its always-mounted refresh
  observer. Give its initial/resume check an explicit owner so conditional home
  advice works without first visiting Settings. Android gating stays intact.
- Refresh permission/phone status on Settings entry and foreground return,
  without permission prompts. Read active GPS preferences from cached node
  state; do not perform storage reads in `build`.

`FakeAppState.diagnosticsSnapshot()` currently force-unwraps an optional builder.
Before Home starts sampling, provide a safe default fixture and overridable
immutable values; otherwise unrelated home tests will fail merely by rendering.
Allow build info injection for About tests too.

### 11.4 Keep component extraction proportional

Extract Home from `main.dart`; keep app composition/theming/lifecycle wiring
clear. Settings and About are new screen files. Good shared candidates are a
width-constrained page, status label, identity avatar/summary, adaptive info row,
and section surface—**only when actually reused**.

Keep home-only connection/activity panels private or feature-local. Reuse and
theme `ActionTile`, `StatusCard`, `BusyStrip`, and dialogs where they still fit.
They have real call sites; deleting them and rewriting those screens is not an
acceptance criterion. Do not pre-create a general-purpose settings/sheet/widget
framework or a dozen one-line wrapper files. Use normal snake_case Dart paths.

## 12. Delivery sequence and change map

Tests accompany every behavior/presentation increment; they are not a final
cleanup phase. Each implemented slice must analyze and pass its relevant tests.

| Phase | Deliverable | Exit condition |
|---|---|---|
| 0 — State fixtures and visual checkpoint | Representative current-data fixtures; proposed Home, Settings, sheet, About; light/dark and large-text renders. | Jason reviews actual renderings of the hierarchy, density, and visual direction before all screens are restyled. Color tables alone do not satisfy this gate. |
| 1 — Observation and correctness seams | Read-only radio health, truthful RX time/provenance, scoped GPS editor model, safe test fakes, small polling/lifecycle hook. | Tests prove scope, invalidation, no extra device I/O, and no runtime/wire changes. |
| 2 — Theme + navigation + Settings/About | Small theme, screen extraction, working Settings port editor/telemetry/support routes, About/legal content. | Controls behave correctly in new locations; recovery-resume hook survives; metadata/license tests pass. |
| 3 — Home and identity switching | Compact identity/connection panels, endpoint copy/help, scoped pending/errors, quick-switch sheet, expandable activity. | State matrix and normal-phone viewport tests pass; identity activation/disconnect behavior is unchanged. |
| 4 — Consistency pass | Identities, Connect scan feedback, Backup, Information, Log, dialogs. | No changed transport/backup/destructive semantics; keyboard, text scale, and existing regression coverage preserved. |
| 5 — Verification and docs | Full gates, visual/accessibility pass, screenshots and navigation docs. | Acceptance checklist below completed, with any unavailable manual/hardware checks explicitly recorded. |

Primary file areas (not a mandatory exhaustive file count):

- `app/lib/main.dart`; new `app/lib/screens/home_screen.dart`,
  `settings_screen.dart`, `about_screen.dart`; `app/lib/theme/`.
- `app/lib/app_view_state.dart`, `app_state.dart`; narrowly scoped additions in
  `services/identity_manager.dart`, connection observation/lifecycle wiring,
  and presentation helpers. Add error-result presentation only if needed;
  do not refactor controller responsibilities or parse log text.
- `packages/device_link/lib/src/shared_radio_link.dart` and
  `link_metrics.dart`, with their direct tests, for passive observations only.
- Existing screen/widget files as actually needed; avoid unrelated formatting,
  package updates, or blanket replacement of working components.
- `app/test/support/fake_app_state.dart`, screen/model/lifecycle tests, and the
  UI-driven integration harnesses listed in §13.
- Documentation and screenshots in §14. `pubspec.yaml` only if existing legal
  text needs asset registration; no package/version changes.

The implementation may choose slightly different file boundaries if the
architecture and testability remain as small. Update this plan when a material
decision changes; do not turn implementation discoveries into silent scope creep.

## 13. Test and verification plan

### Behavioral and data tests

- Table-driven presentation tests for §6, including catalog loading/error,
  unavailable identity, proxy-running/radio-reconnecting, stopped-before-wait,
  client absence, and simulation. Assert what the state means, not just a dot.
- Home viewport test at 360 × 800: essential controls visible without scroll.
  Tests at 320 px and 2.0× check reachability/no overflow rather than enforcing
  an impossible no-scroll requirement.
- Quick switch: active no-op, valid offline/online selection, disabled/key/state
  errors, busy/double taps, delayed failure, dismissal during await, manage-route
  handoff, and no pop of the underlying page. Verify client-disconnect behavior
  through the existing real manager/server simulator tests, not only a mock.
- Copy: exact configured loopback endpoint, including a nondefault port; does
  not copy unrelated report/private data. Test separate host/port copy in setup
  help, and client address vs server endpoint.
- Proxy: pending state, failed start, interrupted recovery, state reconciliation,
  and no false success. Preserve the normal stop and disabled-switch contracts.
- Port: Cancel never writes; invalid input stays editable; boundary values,
  failed/ineligible submit, state changing while dialog is open, IME submission,
  and saved value reflected back on Home. Use labeled/semantic finders.
- GPS regression: identity A off/900 s and B on/60 s; A's switch stays off and
  editor shows 900 while shared status reports demand/60 s. Toggling A affects
  only A. Test identity change during editing/permission dialogs, stored zero,
  missing live node, denied permission, and false setter results.
- Physical health: no sample, successful/zero/invalid-storage readings, null and
  failed read preserving timestamp, normal cadence vs delayed UI warning,
  detach/new target, late old completion, restore, and active-identity switches.
  Verify display/expand/poll causes **no extra `battery()` or stats requests**.
- RX time: timestamp comes from reception, not polling; source changes do not
  relabel old signal as current; cumulative totals remain cumulative.
- Refresh: one timer, only when visible/resumed; no polling under Settings or
  after dispose; immediate refresh on return; no focus/scroll/expansion reset.
  Recovery rearm still happens on foreground return with another route on top.
- Connect scan: success, denied/start failure, timeout with/without results,
  stop/rescan, tab change/dispose, and result selection after scan ends. Keep
  advertisement-name and transport/cancellation regression tests.
- About: installed/ABI build code, complete/partial/missing metadata, dirty
  commit, selectable/copyable source, real license entries and LicensePage.
  Keep diagnostic report redaction/content assertions and backup regressions.

### Existing tests and automation that must move

- Rewrite `app/test/home_screen_test.dart` around the new contract. Move
  port/resume/telemetry controls into Settings tests instead of dropping their
  coverage. Do not retain giant 1200 × 3000 fixtures as the only layout test.
- Add Settings, About, quick-switch, home presentation/refresh, and theme tests
  with the real app theme. Update `identities_screen_test.dart`,
  `connect_screen_test.dart`, `diagnostics_screen_test.dart`,
  `app_surfaces_test.dart`, and lifecycle/app-state tests only as needed.
- Keep meaningful diagnostic/backup/cancellation assertions, not a requirement
  that every existing test file remain byte-identical. Copy may change when it
  is misleading; update tests intentionally rather than preserving bad UX.
- `app/integration_test/live_ui_test.dart` needs **more than port/info edits**:
  route port editing through Settings + dialog; identity management through the
  sheet's Manage action; diagnostics through Support; fix Back navigation for
  the extra routes and repeated identity-management visits.
- Audit `android_ble_ui_test.dart` and the Home-driven cases in
  `connection_recovery_test.dart` for imports, control finders, and recovery
  copy. Preserve the intent of Cancel/wait tests even if labels/layout change.
- Prefer stable keys, accessible labels, and scoped finders for automation;
  do not assert exactly one Image, a private helper type, or a global TextField
  count as a design requirement. Continue using ordinary Material switch
  semantics so interaction tests exercise a real accessible control.

### Automated gates for implementation

Run from the repository root:

```sh
./scripts/check.sh
./scripts/coverage.sh
```

`check.sh` includes format, analysis, and tests. Coverage is a **separate** gate;
`flutter test --coverage` alone does not enforce the repository baseline.
Maintain existing per-file coverage and aim for at least 80% in touched code;
new files must meet the baseline tool's 80% requirement. Do not lower/rewrite
`coverage_baseline.json` to hide a regression. New source paths from extraction
need real coverage, not an exemption because the code used to live elsewhere.

Add a small deterministic golden/render-fixture set using Flutter's existing
test tooling: idle Home, connected Home, waiting/error Home, identity sheet,
Settings, and About; cover both themes and representative large text. Stabilize
time/build info/animations and the SDK/font environment; document intentional
golden updates. Test-font/Ahem renders alone do not validate Android typography.
Also use Flutter accessibility guideline tests for labeled targets, Android
target size, and contrast where applicable. Goldens do not replace
semantic/behavior tests or the Android visual checkpoint.

### Manual visual and accessibility checkpoint

Use an Android emulator/test install with synthetic identities, not a tester's
live catalog. Review default and large font/display settings, light/dark,
keyboard-visible forms/dialogs, short screens, long names, multiline failures,
all recovery states, and sheet focus/Back behavior. Perform a TalkBack traversal
of Home, the switcher, and Settings; verify no duplicate/noisy poll announcements.
Smoke-test Linux keyboard/mouse use and capability gating.

Do not run RF/HIL tests merely to validate navigation. Existing hardware test
entry points remain opt-in and require their documented defines/authorization.
An emulator/simulator proves UI behavior, not BLE reliability, RF delivery, or
Doze/background survival. Record those as unvalidated unless actually tested.

## 14. Completion criteria and documentation

### Required acceptance checklist

- [ ] The reviewed normal-phone layout shows identity, radio, and proxy control
  before secondary metrics; no duplicate status summary or duplicate queue card.
- [ ] Every §6 state has truthful copy and a reachable next step. “Connected” is
  scoped to the radio/listener/client it describes; recovery Cancel still works.
- [ ] Home exposes the configured client endpoint with Copy and setup help,
  including the local-network/plaintext security caveat.
- [ ] Switching works online/offline under existing eligibility rules, explains
  client disconnection, and cannot close the wrong route or double-submit.
- [ ] All selected metrics are available in the stated compact/expanded places,
  accurately scoped; physical/virtual storage and BLE/mesh signal never blur.
- [ ] GPS controls reflect the identity they modify; aggregate phone sampling
  remains separately visible. No new location permission or storage behavior.
- [ ] Settings, About/legal content, and existing screens share the approved
  theme, preserve functional safeguards, and remain useful during failures.
- [ ] No inaccessible/clipped controls at tested sizes; contrast/targets pass,
  reduced motion is respected, and TalkBack/focus checks are recorded.
- [ ] Display refresh is visibility/lifecycle-aware, generates no radio traffic,
  and does not break foreground recovery rearming or battery-status refresh.
- [ ] Full analysis/tests and coverage gates pass; navigation/HIL harness source
  is updated even when hardware runs are unavailable. Scope diff is reviewed.
- [ ] Docs and screenshots match the new navigation, or the remaining visual
  validation is explicitly recorded as incomplete—not called a finished design.

### Documentation work when implementation lands

- `docs/USER_GUIDE.md`: replace the home-card inventory and old log/info/footer
  paths; explain the two connections, copyable endpoint, switch sheet/management,
  queue meaning, activity scope, Settings, scoped GPS, and About. Update setup,
  battery, backup, restore, and troubleshooting paths—not just the home section.
- `README.md`: update quick-start port/identity/battery instructions and where
  version/diagnostics live. Keep same-phone setup primary and security honest.
- `DEVELOPMENT.md`: update **Background execution**, **App state and screen
  boundary**, and **Build metadata and session diagnostics** for new control
  locations, observation ownership, and removal of the home build footer.
- `SECURITY.md`: correct the old “About & diagnostics” destination wording and
  keep GPS/endpoint descriptions consistent. No stronger security claims.
- `CHANGELOG.md`: add an Unreleased summary of the navigation/visual changes
  and deliberate UX fixes. Do not rewrite historical release notes or bump the
  current `0.2.0+1` version as part of UI work.
- Replace outdated affected screenshots; add Settings, About, switcher, and a
  recovery example as useful. Use a repeatable synthetic fixture/viewport/theme,
  freeze timestamps, and document capture provenance. Do not expose real names,
  keys, addresses, or backup material. Review light renders even if the guide
  primarily illustrates dark mode.
- Reuse existing artwork and legal attribution. `ATTRIBUTION.md` needs no new
  upstream-code entry for this work; if legal packaging reveals missing notices,
  address that explicitly rather than declaring the built-in license page complete.

If an emulator or TalkBack device is unavailable, keep text/docs/tests current
and list the missing visual/accessibility checks with a date. This may be a
development handoff, but it does not satisfy the completed-overhaul visual gate.

## 15. Deferred choices and reference material

No unanswered product question blocks the prototype. Exact role colors, avatar
use, panel spacing, and compact activity composition are **visual-review
decisions**, not questions Jason needs to settle by choosing hex codes. Do not
reopen the scope to add charts, a browser-launch package, a new theme preference,
or a navigation framework during styling. Record genuinely new tradeoffs before
implementation rather than hiding them under “polish.”

Primary guidance checked for this revision (2026-11-11):

- [Android app settings](https://developer.android.com/design/ui/mobile/guides/patterns/settings):
  infrequent preferences, contextual frequent actions, clear dependency reasons,
  grouped lists, secondary access, and bounded widths. Support links in Settings
  are a pragmatic choice for this small utility; app metadata itself lives in
  About rather than cluttering the preferences list.
- [Android runtime permission principles](https://developer.android.com/training/permissions/requesting):
  ask in context, support denial/cancellation, and degrade without blocking the
  unrelated app. Existing platform permission code remains authoritative here.
- [Flutter accessibility](https://docs.flutter.dev/ui/accessibility):
  meaningful interactions, screen-reader testing, contrast, target size, error
  recovery, and large-scale usability.
- [Flutter `showLicensePage`](https://api.flutter.dev/flutter/material/showLicensePage.html):
  the built-in page displays registered licenses; project notices need to be
  verified, not assumed.

Key implementation sources:

- `app/lib/main.dart` and `app/lib/screens/`: current layout and interactions.
- `app/lib/app_view_state.dart` and `app/lib/app_state.dart`: screen boundary,
  snapshot construction, setters, and aggregate phone status.
- `app/lib/services/identity_runtime.dart` and
  `app/lib/services/identity_manager.dart`: selection eligibility and hub ownership.
- `app/lib/services/phone_location_service.dart`: shared GPS demand/cadence.
- `app/lib/services/proxy_controller.dart`: serialized listener transitions.
- `app/lib/services/build_info.dart` and
  `app/lib/services/diagnostics_snapshot.dart`: existing metadata/report helpers.
- `packages/device_link/lib/src/link_metrics.dart` and
  `packages/device_link/lib/src/shared_radio_link.dart`: physical observations.
- `packages/mesh_node/lib/src/battery_service.dart` and
  `packages/mesh_node/lib/src/mesh_node.dart`: existing battery freshness and the
  virtual-storage boundary; reviewed for context, not proposed for modification.

Consult those sources again before implementation; this is a reviewed plan,
not a substitute for checking the code at the time of the change.

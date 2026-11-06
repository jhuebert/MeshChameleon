# Phone battery percentage and phone GPS telemetry

Status: implementation-ready plan.

This file is the handoff document for adding phone battery percentage and phone
GPS to the MeshChameleon virtual companion. Read it together with `AGENTS.md`,
`README.md`, `DEVELOPMENT.md`, and `SECURITY.md`. Do not edit the reference
repositories (`MeshCore/`, `meshcore-open/`, `openhop_core/`).

## 1. Goal

Add exactly two phone-sourced pieces of data to the existing virtual companion
telemetry:

1. **Phone battery percentage**, exposed under the base telemetry permission.
2. **Phone GPS fix**, exposed under the location telemetry permission and also
   used for adverts and `SELF_INFO`, behaving like a stock companion with a GPS
   module.

Everything else already in telemetry stays as it is: the attached radio's
battery voltage is still the first/base voltage value, and the existing
telemetry request/permission/reply flow is preserved.

## 2. Locked scope and non-goals

### Included

- Phone battery percentage from `battery_plus`.
- Phone GPS latitude, longitude, and altitude from `geolocator`.
- `gps` custom setting to enable/disable phone GPS.
- `gps_interval` custom setting for the update cadence.
- GPS feeding adverts and `SELF_INFO` through the existing `NodePrefs`
  coordinates.
- Phone GPS included in self telemetry when GPS is enabled.
- App-side location permission UI and diagnostics.
- Android background location permission and foreground-service type.
- Tests and documentation.

### Explicitly excluded

- Raw Android battery status.
- Phone battery temperature.
- Charging state.
- Connectivity / Wi-Fi vs mobile.
- Barometric pressure.
- Ambient temperature.
- GPS speed and heading.
- Any custom native Kotlin channel.
- Any new node-state schema or migration.
- Any new environment-sensor fields.
- iOS.

Do not add these opportunistically. They add platform code and test surface
without being part of this change.

## 3. Current behavior and relevant code

Current telemetry flow:

- `packages/mesh_node/lib/src/mesh_rx.dart`
  - `_onRequest` validates a persistent contact and telemetry permissions.
  - `_grantedTelemetryPermissions` applies the owner's telemetry modes plus
    contact class flags and the inverse mask.
  - `_encodeTelemetryLpp` currently writes the radio voltage and optional GPS
    from `prefs.latitude` / `prefs.longitude`, with altitude hard-coded to 0.
  - `_writeSigned24` encodes the 24-bit CayenneLPP values.
  - `_sendTelemetryReply` schedules the direct/flood reply.
- `packages/mesh_protocol/lib/src/telemetry_codec.dart`
  - `encodeSelfVoltageTelemetry` writes channel 1, type `0x74`, mV/10.
- `packages/mesh_node/lib/src/mesh_node.dart`
  - Owns `BatteryService` for the attached radio's voltage.
  - `prefs` is the live `NodePrefs`; adverts and `SELF_INFO` read
    `prefs.latitude` / `prefs.longitude`.
  - `setAdvertLatLon` commits manual coordinates.
  - `setCustomVar` validates through `VirtualSensorSettingsProvider` and
    persists accepted settings in `NodeState.customSettings`.
- `packages/companion_server/lib/src/command_dispatcher.dart`
  - `_cmdSendTelemetryReq` answers a 3-byte self request directly with
    `encodeSelfVoltageTelemetry`, bypassing `MeshNode`.
- `packages/companion_server/lib/src/bridge.dart` /
  `capabilities.dart`
  - `CompanionBridge` is the app-facing host interface implemented by
    `MeshNode`.
- `packages/mesh_node/lib/src/sensor_settings.dart`
  - `VirtualSensorSettingsProvider` currently has `initialSettings`,
    `supports`, and `normalize`.
  - The default provider supports nothing, so `GET_CUSTOM_VARS` currently
    returns an empty list and clients hide GPS settings.
- `app/lib/services/identity_runtime_builder.dart`
  - Constructs each live `MeshNode`.
- `app/lib/services/identity_manager.dart`
  - Owns live runtimes and retires/removes them.
- `app/lib/services/foreground_service.dart`
  - Starts the foreground service with `ForegroundServiceTypes.connectedDevice`.
- `app/android/app/src/main/AndroidManifest.xml`
  - Currently has location permission only for legacy BLE, capped at API 30.
- `app/lib/main.dart` / `app/lib/screens/diagnostics_screen.dart`
  - App status UI. Add a small phone telemetry/GPS card and diagnostics.

Stock behavior to preserve:

- Base permission is required before any telemetry reply is sent.
- Radio voltage is channel 1 and the first LPP entry.
- GPS uses channel 1 and the location permission.
- Self telemetry includes all available local telemetry regardless of the
  owner's remote telemetry modes.
- `SELF_INFO` and adverts use `prefs.latitude` / `prefs.longitude`;
  `advertLocPolicy` decides whether adverts include them.

## 4. Protocol contract

### 4.1 LPP entries

Only two new logical values are added, and one of them is the existing GPS
entry now sourced from the phone.

| Channel | Permission | LPP type | Field | Encoding |
|---:|---|---|---|---|
| 1 | Base | `0x74` voltage | Attached radio battery voltage | 0.01 V, unsigned, unchanged |
| 1 | Base | `0x78` percentage | Phone battery percentage | 0–100, unsigned byte |
| 1 | Location | `0x88` GPS | Phone latitude/longitude/altitude | lat/lon 0.0001°, alt 0.01 m |

Ordering:

1. Radio voltage (always, unchanged, first).
2. GPS when location permission is granted, GPS is enabled, and a usable
   current location exists.
3. Phone battery percentage when base permission is granted and the value is
   available.

This mirrors stock's `voltage` then `sensors.querySensors()` ordering, with the
phone percentage appended as a virtual extension.

No environment fields are added. The environment permission remains available
for future use but currently adds nothing.

### 4.2 Omission rules

Never send a fabricated or zero-default value for a missing phone value.

- Phone battery unavailable or read failed/timed out: omit the percentage
  entry.
- `gps` is `"0"`: omit the GPS entry.
- `gps` is `"1"` but there is no usable location (`0,0` fresh install): omit
  the GPS entry.
- `gps` is `"1"` and coordinates exist: include GPS. If altitude is unknown,
  encode altitude as `0` (the LPP GPS field always has an altitude).
- Phone battery percentage out of range: clamp to 0–100 before encoding.
- GPS coordinates invalid (non-finite, out of range): reject the fix at the
  `MeshNode` boundary; do not encode it.

A phone battery failure must never prevent the radio voltage reply.

### 4.3 Permissions

Keep the existing `_grantedTelemetryPermissions` logic exactly as-is:

- base/location/environment owner modes;
- contact class flags when the mode is `TELEM_MODE_ALLOW_FLAGS`;
- inverse request mask;
- base bit required to reply at all.

Phone battery percentage is gated by the base bit. GPS is gated by the location
bit plus the node's `gps` setting.

### 4.4 Self telemetry

Stock answers a 3-byte self telemetry request with all available local
telemetry (`sensors.querySensors(0xFF, ...)`), not the remote permission mask.
Match that:

- Add `Future<Uint8List> getSelfTelemetry()` to `CompanionBridge`.
- Implement it in `MeshNode`, using the shared telemetry assembler with
  `telemPermBase | telemPermLocation`.
- Include phone battery percentage whenever it is available.
- Include GPS whenever `gps` is enabled and a usable location exists.
- Do not require a contact or remote telemetry permission.
- Update `command_dispatcher._cmdSendTelemetryReq` to call the bridge method
  instead of encoding voltage directly.
- Update the test bridge/fakes so existing self-telemetry tests remain
  deterministic.

### 4.5 Size and timing

- Add a size-budget test: the maximum payload (voltage + GPS + percentage) must
  fit comfortably after response framing within
  `maxPacketPayloadSize` (184 bytes).
- Phone battery read timeout: 1 second. On timeout, omit the percentage.
- Keep the existing reply scheduling and flood/direct behavior.
- Re-check the identity generation after all awaits and before scheduling the
  reply.
- Incoming telemetry requests must never trigger a GPS sample. They only read
  the node's last known/current location.

## 5. GPS behavior

### 5.1 Settings

Implement an app-side `VirtualSensorSettingsProvider` per identity.

`gps`:

- `initialSettings` contains `'gps': '0'`.
- `supports('gps')` is true.
- `normalize('gps', value)` accepts only `"0"` or `"1"` after trim; return
  `null` for anything else.
- Advertise it in `GET_CUSTOM_VARS`, because the phone has GPS hardware. This
  makes `meshcore-open` show its existing GPS toggle.

`gps_interval`:

- `initialSettings` contains `'gps_interval': '900'`.
- `supports('gps_interval')` is true.
- Parse as an integer. Reject non-numeric values.
- Clamp to the stock range `0..86400`.
- Return the normalized decimal string.
- Advertise it in `GET_CUSTOM_VARS`. Stock firmware accepts this setting but
  does not advertise it; this is an intentional virtual-only difference so the
  client can show the current phone cadence.

Effective cadence:

```text
effective_seconds = stored_seconds > 0 ? stored_seconds : 1
```

The default is 900 seconds for phone battery life. The full stock range is
supported, including `0` (effective 1 second) and `86400`.

`gps=1` is persisted even if location permission is currently missing. The app
shows a permission-required status rather than silently changing the setting
back to `0`.

### 5.2 What GPS updates

When a phone fix is applied and accepted:

- Update `prefs.latitude` and `prefs.longitude` in memory.
- Adverts, self adverts, contact export, and `SELF_INFO` automatically use
  those existing fields.
- `advertLocPolicy` still controls whether adverts include coordinates.
- Keep altitude only in memory for the LPP GPS entry.
- Manual `CMD_SET_ADVERT_LATLON` continues to work. It updates
  `prefs.latitude/longitude` and must clear the in-memory GPS altitude/fix so
  manual coordinates are not mixed with stale GPS details. The next phone fix
  overwrites the coordinates, matching stock.
- `gps=0` means no GPS LPP entry. Manual coordinates still drive adverts.
- A fresh install with `0,0` and no fix omits GPS from telemetry.
- After a restart, persisted coordinates are the last known location. This
  mirrors stock restoring `node_lat` from preferences. A cold start before a
  new fix may therefore report the persisted location, which may have been
  manually entered. Document this nuance.

### 5.3 Applying fixes and persistence

Add:

```dart
class VirtualLocationFix {
  const VirtualLocationFix({
    required this.latitude,
    required this.longitude,
    this.altitudeMeters,
    required this.capturedAt,
  });

  final double latitude;
  final double longitude;
  final double? altitudeMeters;
  final DateTime capturedAt;
}
```

Add to `MeshNode`:

```dart
Future<void> applyLocationFix(VirtualLocationFix fix);
```

Behavior:

- Ignore the fix unless this node currently has `gps=1`.
- Validate finite coordinates and ranges before applying.
- Store the fix in memory for altitude and diagnostics.
- Update `prefs.latitude` / `prefs.longitude` directly in memory. Do **not**
  call `_commit` for every fix: with `gps_interval=1` that would write the
  entire node state every second.
- Mark location state dirty.
- Persist location through the existing state path when:
  - a normal state commit occurs (the live `prefs` snapshot includes the
    coordinates);
  - `gps` changes to `0` (`setCustomVar` already commits and will include the
    live coordinates);
  - the node is stopped/retired: if dirty, call the existing
    `_state.persist()` before the retire wait.
- Do not call `_notifyStateChanged()` on every fix. That would cause a UI
  refresh storm at low intervals. Diagnostics can poll the current status.
- On reset, clear the in-memory fix. The reset path already restores default
  preferences.
- On `gps=0`, keep the last fix in memory but do not apply new fixes and do not
  emit GPS telemetry.

This storage strategy is intentional: stock also updates its live
`sensors.node_lat` continuously and only writes location to preferences when
preferences are saved.

### 5.4 App location timer

Create a single app-level `PhoneLocationService`. It owns one timer for all
identities.

State:

- bound nodes by identity id;
- last observed settings by identity id;
- one `Timer?`;
- `_sampling` guard;
- `_lastFix`;
- permission status;
- last attempt/success/error for diagnostics.

Demand and interval:

- Demand exists when at least one bound identity has `gps=1`.
- The timer interval is the smallest effective `gps_interval` among identities
  with `gps=1`.
- When multiple identities request GPS, all receive each fix; the phone does
  not sample once per identity.
- Start the first sample immediately when demand first appears.
- If the interval changes, cancel and reschedule. Do not sample more often than
  the new interval unless there has been no successful fix yet.
- Stop and cancel the timer when no identity has `gps=1`, the session stops, or
  the app is disposed.

Sampling algorithm:

```text
_tick():
  if _sampling: return
  if no demand or no permission: return
  _sampling = true
  try:
    last = await Geolocator.getLastKnownPosition()
    if last is valid and age(last) <= effective interval:
      apply(last)
    else:
      fix = await Geolocator.getCurrentPosition(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: 30s,
          useMSLAltitude: true,
        ),
      )
      apply(fix)
  catch:
    record diagnostic; keep previous fix
  finally:
    _sampling = false
    if demand and permission:
      schedule next in effective interval seconds
```

Rules:

- Never use `getPositionStream()` for this feature. Use bounded one-shot
  requests so GPS hardware is not kept warm continuously.
- Never overlap samples. If a 1-second interval is configured, the next attempt
  starts after the previous attempt completes; the effective cadence may be
  slower than 1 second.
- `getLastKnownPosition()` must be validated and age-checked before use.
- Medium accuracy is sufficient for mesh telemetry and is easier on the
  battery than high accuracy.
- A telemetry request never schedules a sample.
- If a sample fails, do not retry immediately; wait for the next scheduled
  attempt.
- On app resume, if demand exists and the last success is older than the
  interval (or there is no success), schedule an immediate sample. Never sample
  more than once per interval because of lifecycle events.

### 5.5 Permissions and background execution

Android permissions:

- Add `ACCESS_COARSE_LOCATION`.
- Keep `ACCESS_FINE_LOCATION`; remove the existing `maxSdkVersion="30"` cap
  because GPS needs it on supported versions.
- Add `ACCESS_BACKGROUND_LOCATION` for background sampling.
- Add `FOREGROUND_SERVICE_LOCATION`.
- Include `location` in the foreground-service declaration:
  `android:foregroundServiceType="connectedDevice|location"`.

App permission flow:

- Use `Geolocator.checkPermission()` / `requestPermission()`.
- Explain why location is needed before prompting.
- `whileInUse` permits foreground sampling. Background sampling should request
  `always`; on Android 11+ the user must grant “Allow all the time” in system
  settings. Provide a button to `Geolocator.openAppSettings()`.
- A denied/denied-forever permission is not fatal: `gps` stays persisted, no
  fixes are applied, and diagnostics/UI report the blocker.
- Do not auto-open a permission dialog from a remote `SET_CUSTOM_VAR`. Surface
  a banner/status in the app instead.

Foreground service:

- Add `location` to `ForegroundService.start`'s `serviceTypes` when location
  access is granted.
- Prefer keeping the existing single notification; do not add a second
  location notification unless the existing foreground service cannot satisfy
  Android's requirements.
- If permission is granted after the service has started, restart the service
  from the app while it is in the foreground so the `location` type is added.
  If the service type cannot be changed while running, document the restart and
  preserve the notification text.
- The foreground-service type is permission plumbing only. It does not imply
  continuous polling; the timer still controls sampling.
- Verify the merged manifest and Android 12–15 behavior on hardware.

## 6. Architecture and design principles

This change must follow the repository's existing patterns and general
software/mobile best practices.

### Architecture

- Keep `packages/mesh_protocol`, `packages/mesh_node`, and
  `packages/companion_server` free of Flutter and Android imports.
- Platform-specific code belongs in `app/`.
- Use dependency injection and constructor callbacks, matching
  `BatteryService(readVoltage: ...)` and the existing scheduler/timer
  injection patterns.
- Keep one source of truth for LPP assembly: a shared telemetry assembler used
  by both remote replies and self telemetry.
- Keep one source of truth for location sampling: one app-level service and
  one timer for all identities.
- Keep one source of truth for GPS settings: the `gps` / `gps_interval` custom
  vars, written by both the client and the app UI.
- Do not add a generic phone telemetry abstraction for a single battery field.
  Inject a `Future<int?> Function()` and keep the code direct.
- Do not add new persistence formats or schema versions. Use existing
  `NodePrefs` and `customSettings`.

### DRY

- Do not duplicate LPP GPS/percentage encoding between `mesh_rx.dart` and
  `command_dispatcher.dart`.
- Do not duplicate GPS timer logic in `AppState`, `IdentityManager`, and each
  node.
- Do not reimplement permission mapping; reuse
  `_grantedTelemetryPermissions`.
- Do not reimplement location validation in multiple layers; validate once at
  the `MeshNode.applyLocationFix` boundary and once at LPP encoding for
  representable ranges.

### Mobile best practices

- Request permissions just in time and explain them.
- Handle all permission states: granted, denied, denied forever, while-in-use,
  always.
- Respect Android background-location restrictions and foreground-service
  type rules.
- Prefer one-shot work over continuous sensors when freshness does not require
  a stream.
- Stop timers and sensor listeners when there is no demand.
- Do not log location coordinates, precise sensor values, or other sensitive
  data in normal logs.
- Use medium accuracy for telemetry; high accuracy is not needed.
- Keep the app usable when GPS is unavailable or denied.
- Validate on real Android 12–15 devices before claiming background behavior
  works.

### Code quality

- Small focused changes, matching surrounding style.
- Add regression tests for every behavior and edge case.
- Keep new production files at or above 80% line coverage; do not lower an
  existing file's coverage.
- Update documentation when behavior or stock-parity differences change.
- Do not bundle unrelated cleanup or dependency upgrades.
- Do not edit reference repositories.
- Do not commit unless explicitly asked.

## 7. Implementation steps

### 7.1 `packages/mesh_protocol`

Files:

- `lib/src/telemetry_codec.dart`
- `test/telemetry_codec_test.dart`

Add:

- `encodeTelemetryPercentage(int channel, int percent)`:
  - clamp 0–100;
  - writes `channel`, `0x78`, one unsigned byte.
- `encodeTelemetryGps(int channel, double latitude, double longitude,
  double? altitudeMeters)`:
  - validates finite ranges;
  - clamps to signed 24-bit representable values;
  - writes `channel`, `0x88`, lat, lon, altitude;
  - altitude defaults to 0 when null.
- A shared signed-24-bit helper, moved from `mesh_rx.dart`.
- Keep `encodeSelfVoltageTelemetry` byte-for-byte compatible; it may delegate
  to a generalized voltage helper.

Tests:

- percentage 0, 1, 100, negative, over 100;
- GPS positive/negative coordinates, altitude null/0/negative, clamp;
- exact bytes for known values;
- existing voltage bytes unchanged.

### 7.2 `packages/mesh_node`

Files:

- new `lib/src/phone_location.dart` (`VirtualLocationFix`)
- new `lib/src/telemetry_assembler.dart`
- `lib/src/mesh_rx.dart`
- `lib/src/mesh_node.dart`
- `lib/src/sensor_settings.dart`
- `lib/mesh_node.dart` export the new type(s)
- tests: `test/telemetry_test.dart`, `test/mesh_node_test.dart`, fakes

#### Telemetry assembler

Create one collaborator that owns LPP assembly.

Suggested constructor dependencies:

```dart
TelemetryAssembler({
  required BatteryService battery,
  required NodePrefs prefs,
  required bool Function() gpsEnabled,
  required VirtualLocationFix? Function() locationFix,
  required Future<int?> Function()? readPhoneBatteryPercent,
})
```

Suggested method:

```dart
Future<Uint8List> build(int permissions) async;
```

Behavior:

- Always refresh the radio battery and encode voltage first.
- Wait at most 1 second for the phone battery percentage. On error/timeout,
  omit it.
- Add phone percentage only when the base permission bit is set and the value
  is non-null.
- Add GPS only when the location permission bit is set, `gpsEnabled()` is true,
  and `prefs.latitude` / `prefs.longitude` are not both zero.
- Use `locationFix()?.altitudeMeters` for GPS altitude; encode 0 when unknown.
- Return the LPP bytes.

Do not put `isCurrent(generation)` checks inside the assembler; the caller owns
identity-generation checks.

#### `MeshRx`

- Add the assembler to `MeshRxDeps`.
- In `_onRequest`, after validating permissions and confirming base, call
  `deps.telemetry.build(permissions)`.
- Check identity generation after the await and before scheduling the reply.
- Remove `_encodeTelemetryLpp` and `_writeSigned24` from `mesh_rx.dart` once the
  assembler owns them.

#### `MeshNode`

- Add constructor parameter `Future<int?> Function()? readPhoneBatteryPercent`.
- Create the assembler after `BatteryService` and use it in `MeshRx`.
- Add `bool get gpsEnabled => _customVars['gps'] == '1';`.
- Add `VirtualLocationFix? get locationFix`.
- Add `Future<void> applyLocationFix(VirtualLocationFix fix)`.
- Add `Future<Uint8List> getSelfTelemetry()` using the assembler with
  `telemPermBase | telemPermLocation`.
- In `setAdvertLatLon`, clear the in-memory location fix after updating manual
  coordinates.
- In `stop()` / `retire()`, persist dirty location via the existing state path.
- Clear the in-memory location fix during reset.

#### `VirtualSensorSettingsProvider`

Add a default no-op method:

```dart
void onSettingsChanged(Map<String, String> settings) {}
```

Call it:

- at the end of `MeshNode.load()` after settings are merged;
- after a successful `setCustomVar`;
- after reset restores initial settings;
- after start, idempotently.

This keeps side effects (starting/stopping the location timer) out of
`normalize()`, which is also called while loading persisted state.

#### Tests

- Base request includes radio voltage and phone percentage when available.
- Phone percentage unavailable/timeout/error still returns radio voltage.
- Location request with `gps=1` includes GPS and altitude.
- `gps=0` omits GPS.
- `gps=1` with `0,0` and no fix omits GPS.
- Base-only request still required; environment alone gets no reply.
- Identity change during sampling prevents a reply.
- `applyLocationFix` updates adverts and `SELF_INFO`.
- `applyLocationFix` is ignored when `gps=0`.
- Manual `setAdvertLatLon` clears in-memory GPS altitude; next fix overwrites.
- Reset clears location state.
- `gps` / `gps_interval` normalize and persist; invalid values rejected.
- Settings callback fires on load/set/reset.
- Multi-identity nodes have independent `gps` settings.
- Self telemetry includes percentage and GPS when enabled.

### 7.3 `packages/companion_server`

Files:

- `lib/src/bridge.dart`
- `lib/src/capabilities.dart`
- `lib/src/command_dispatcher.dart`
- `test/support/test_bridge.dart`
- relevant tests

Changes:

- Add `Future<Uint8List> getSelfTelemetry()` to `CompanionBridge` with an
  unsupported default.
- Implement it in `MeshNode`.
- In `_cmdSendTelemetryReq`, replace the direct voltage build with
  `await host.bridge.getSelfTelemetry()`.
- Remove now-unused imports (`encodeSelfVoltageTelemetry` if it was only used
  there).
- Update fakes so existing self-telemetry tests still produce deterministic
  bytes.

Tests:

- self telemetry includes phone percentage/GPS;
- existing voltage offset test still passes when no phone source is present;
- GET/SET custom vars with `gps` and `gps_interval`;
- invalid `gps` / `gps_interval` values return the expected error.

### 7.4 `app` services

Files:

- new `lib/services/phone_battery_service.dart`
- new `lib/services/phone_location_service.dart`
- new `lib/services/phone_sensor_settings.dart`
- `lib/services/identity_runtime_builder.dart`
- `lib/services/identity_manager.dart`
- `lib/app_state.dart`
- `lib/app_view_state.dart`
- `lib/services/diagnostics_snapshot.dart`
- `lib/services/foreground_service.dart`
- `lib/services/foreground_controller.dart`
- `lib/main.dart` or a small widget file
- `lib/screens/diagnostics_screen.dart`
- `pubspec.yaml`
- Android manifest
- app tests and `test/support/fake_app_state.dart`

#### Dependencies

Add only:

- `battery_plus`
- `geolocator`

Do not add `sensors_plus`, `connectivity_plus`, or a custom platform channel.
Use versions compatible with the current Flutter stable and let the existing
dependency tooling manage upgrades. Do not upgrade unrelated packages.

#### `PhoneBatteryService`

- Wrap `battery_plus`.
- `Future<int?> read()`:
  - read `Battery().batteryLevel`;
  - clamp 0–100;
  - catch all platform errors and return `null`;
  - no continuous stream required. A short cache is optional and unnecessary
    unless profiling shows platform-channel churn.
- Pass `read` into each `MeshNode` as `readPhoneBatteryPercent`.

#### `PhoneSensorSettingsProvider`

- One instance per identity.
- Holds the identity id and a reference to `PhoneLocationService`.
- `initialSettings`: `{'gps': '0', 'gps_interval': '900'}`.
- `supports`: `gps` and `gps_interval`.
- `normalize`: as specified in section 5.1.
- `onSettingsChanged`: forward a copy of the map to
  `PhoneLocationService.updateSettings(identityId, settings)`.

#### `PhoneLocationService`

- Single app-level service.
- Injected timer factory: `Timer Function(Duration, void Function())` for
  tests, matching the app's existing timer-injection style.
- Methods:
  - `bindNode(String identityId, MeshNode node)`
  - `unbindNode(String identityId)`
  - `updateSettings(String identityId, Map<String, String> settings)`
  - `Future<bool> requestForegroundPermission()`
  - `Future<bool> openLocationSettings()`
  - status getters for diagnostics/UI.
- Track demand and effective interval as described in section 5.4.
- `bindNode` must happen after `node.load()` and before/after `node.start()` as
  appropriate, so persisted preferences are not overwritten by a late fix.
- `updateSettings` may be called before `bindNode`; store the settings and
  reconcile when a node is bound.
- Apply fixes to all bound nodes whose settings say `gps=1`; catch per-node
  errors so one identity cannot break the others.
- Cancel the timer and clear demand on session stop/dispose.
- Do not log coordinates.

#### Wiring

`IdentityRuntimeBuilder.start`:

1. Create a `PhoneSensorSettingsProvider` for the record id.
2. Pass it and `readPhoneBatteryPercent` into `MeshNode`.
3. `await node.load()`.
4. Bind the node to `PhoneLocationService`.
5. Sync the provider with `node.getCustomVars()` (idempotent).
6. Start the node and finish normal startup.

`IdentityManager`:

- Receive the services (or a small holder) from `AppState`.
- Pass them to the runtime builder.
- Call `phoneLocation.unbindNode(id)` in:
  - `stopLive`;
  - `delete`;
  - the disable branch of `setEnabled`;
  - any other path that retires/removes a runtime.

`AppState`:

- Own the `PhoneBatteryService` and `PhoneLocationService` instances.
- Allow injection in the constructor for tests.
- Pass them to `IdentityManager`.
- Expose status for diagnostics/UI.
- Request location permission via the location service.
- Ask the foreground controller to refresh its service types when permission
  changes.

#### Foreground service

- Add an `includeLocation` flag to `ForegroundService.start`.
- Include `ForegroundServiceTypes.location` when location access is granted.
- Add a controller/service method to re-evaluate and restart the service if the
  location type needs to change.
- Preserve the current title/text and avoid a second notification where
  possible.
- Handle failures honestly in diagnostics; do not crash the proxy.

#### UI

Keep the UI small:

- A “Phone telemetry” card on the home screen or diagnostics screen showing:
  - phone battery percentage;
  - GPS requested/enabled state;
  - location permission state;
  - last fix age / last error (no coordinates);
  - effective interval;
  - a GPS enable switch for the active identity that writes the same
    `gps` custom var the client uses;
  - an optional interval input that writes `gps_interval` (0–86400);
  - buttons to request location permission and open system settings for
    background location.
- Do not show coordinates in normal logs or copied diagnostics.
- If the UI has no active node, disable the controls.
- The app switch is not a second sharing gate; mesh telemetry permissions still
  control who receives the data.

#### Diagnostics

Add to `DiagnosticsSnapshot`:

- phone battery percentage;
- GPS requested state;
- location permission label;
- effective interval;
- last fix age;
- last location error;
- whether the foreground service includes the location type.

Do not include latitude/longitude in the copied report by default.

#### App tests

- `PhoneBatteryService` maps success, zero, out-of-range, and platform errors.
- `PhoneSensorSettingsProvider` supports/normalizes/persists.
- `PhoneLocationService` with a fake timer:
  - no timer without `gps=1`;
  - no timer without permission;
  - one timer for multiple identities;
  - shortest interval wins;
  - first sample immediate;
  - no overlapping samples;
  - timeout keeps last fix and schedules next;
  - interval change reschedules;
  - no demand stops the timer;
  - fixes applied only to `gps=1` nodes;
  - per-node apply failures do not stop others.
- `IdentityRuntimeBuilder` binds after load and unbinds on retire.
- `IdentityManager` unbinds on stop/delete/disable.
- Widget tests for the phone telemetry card and permission states.
- Update `FakeAppState` for any new view-state getters.

### 7.5 Android

Manifest:

```xml
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/>
```

- Remove `android:maxSdkVersion="30"` from `ACCESS_FINE_LOCATION`.
- Keep `BLUETOOTH_SCAN` `neverForLocation`.
- Update the service declaration to include `location` in
  `android:foregroundServiceType`.
- Verify the merged manifest after building; plugin manifests can affect it.
- Check `geolocator` Android requirements against the current compileSdk.
- Do not add `SCHEDULE_EXACT_ALARM` or unrelated permissions.

### 7.6 Documentation

Update:

- `README.md` — feature summary.
- `DEVELOPMENT.md`:
  - new phone telemetry/GPS section;
  - LPP channel map;
  - permission mapping;
  - GPS timer and battery behavior;
  - stock-parity differences;
  - note that GPS coordinates are persisted through normal node preferences and
    can be included in backups.
- `SECURITY.md`:
  - phone GPS is exposed only to contacts with location telemetry permission;
  - background location permission;
  - backup contains the last location through node preferences;
  - no coordinates in logs.
- `CHANGELOG.md` — unreleased entry.
- `ATTRIBUTION.md` — only if code is adapted; normal package dependencies do not
  require attribution changes. Check licenses if unsure.

Document these intentional differences:

- Phone battery percentage is a virtual addition on channel 1 under base
  permission; stock base telemetry has voltage and MCU temperature.
- `gps` is advertised because a phone has GPS hardware; permission may still
  block fixes.
- `gps_interval` is advertised (stock accepts but does not advertise it) and
  defaults to 900 seconds (stock's internal default behavior is effectively
  1 second).
- `gps_interval=0` is accepted and means 1 second effective, for stock
  compatibility.
- One-shot sampling means very small intervals may not achieve a literal
  1-second cadence; there is never an overlapping request.
- GPS telemetry is omitted when `gps=0`; manual coordinates still drive adverts.
- No MCU temperature, raw battery status, battery temperature, charging state,
  connectivity, pressure, ambient temperature, speed, or heading are
  synthesized.

## 8. Tests and verification

Run from the repository root:

```sh
./scripts/check.sh
```

This runs pub get, format, analyze, and tests for every package and the app.
All new failures must be fixed. Do not hand off with analysis warnings.

For coverage:

```sh
./scripts/coverage.sh
```

New production files must be at or above 80% line coverage. If the baseline
needs the new files added, update it only after the tests pass:

```sh
./scripts/coverage.sh --write-baseline
```

Do not lower any existing file's coverage. Check `git diff` on
`coverage_baseline.json` and make sure only new files or legitimate changes are
present.

Targeted iteration:

```sh
(cd packages/mesh_protocol && dart test)
(cd packages/mesh_node && dart test)
(cd packages/companion_server && dart test)
(cd app && flutter test)
```

Hardware testing (not part of the default gate):

- Real phone with GPS, Android 12–15 if possible.
- Enable `gps` from the MeshCore client; verify the permission flow and that
  telemetry from another node contains GPS.
- Verify adverts contain the phone location when `advertLocPolicy` allows it.
- Verify `SELF_INFO` reflects the phone location.
- Disable `gps`; verify no GPS LPP entry, manual coordinates still used for
  adverts, and the timer stops.
- Verify `gps_interval` values including 0/1, 900, and 86400. Confirm no
  overlapping samples and that the battery cost scales with the setting.
- Background the app; verify fixes continue with the foreground service and
  background permission.
- Revoke/deny location permission; verify the proxy still returns base
  telemetry and the app reports the blocker.
- Verify phone battery percentage updates while charging and discharging.
- Multi-identity: one identity with `gps=1`, another with `gps=0`; verify only
  the enabled identity gets GPS and only one location timer runs.
- Reset/disable/delete an identity; verify the location timer stops when no
  demand remains.

Do not claim hardware validation until it has actually been run. Record the
results and device versions in the handoff report.

## 9. Risks and gotchas

- **Background location restrictions:** Android 12–15 can block or throttle
  background fixes without the correct permission and foreground-service type.
  Validate on hardware.
- **Foreground-service type changes:** adding the `location` type may require a
  service restart. Starting a location foreground service from the background
  is restricted; do the restart from a foreground app when possible.
- **`gps_interval=1`:** allowed for stock parity, but inherently battery-heavy.
  Never overlap requests and document the cost.
- **`getLastKnownPosition` may be stale or from another app.** Age-check it and
  validate coordinates.
- **Altitude may be missing or zero.** The LPP GPS entry always carries an
  altitude; encode 0 when unknown.
- **Manual coordinates while GPS is enabled:** stock lets manual coordinates
  overwrite the current location until the next GPS update. Clear in-memory
  altitude when manual coordinates are set so telemetry is not mixed.
- **Persisting every fix would be expensive.** Use in-memory prefs updates and
  persist only through normal state saves / disable / stop.
- **Direct prefs mutation and state commits:** `prefs` is live; normal commits
  snapshot the current coordinates. Do not add a second preference model.
- **Settings callback ordering:** the provider may receive settings before the
  app service binds the node. Store settings first, reconcile on bind.
- **`MeshNode.load()` overwrites prefs.** Bind/sync after load so a fix cannot
  be lost to the load path.
- **Self telemetry is not permission-filtered.** Do not accidentally require
  remote telemetry permissions for the local self request.
- **Test bridge:** adding a bridge method requires updating fakes so existing
  self-telemetry tests do not hit an unsupported default.
- **No new schema:** do not bump `nodeStateSchemaVersion` for this feature.
  `gps` and `gps_interval` already fit `customSettings`; altitude is ephemeral.
- **Privacy:** do not log coordinates or include them in copied diagnostics.
  Backups already include node preferences and therefore the last location.

## 10. Acceptance criteria

- With base telemetry permission, a persistent contact receives radio voltage
  (first, unchanged) and phone battery percentage when available.
- With location permission and `gps=1`, the same contact receives phone
  latitude/longitude/altitude.
- With `gps=0`, no GPS LPP entry is sent; manual coordinates still drive
  adverts.
- With no fix or zero coordinates, no GPS entry is sent; base telemetry still
  replies.
- Phone battery failure never suppresses the radio voltage reply.
- Self telemetry includes phone battery percentage and GPS when enabled,
  regardless of owner telemetry modes.
- `GET_CUSTOM_VARS` advertises `gps` and `gps_interval`; `SET_CUSTOM_VAR`
  accepts `gps:0/1` and `gps_interval:0..86400` and rejects invalid values.
- The default `gps_interval` is 900; effective interval is 1 for stored 0,
  otherwise the stored value.
- GPS is sampled by a single demand-driven one-shot timer; telemetry requests do
  not trigger samples; no samples overlap; the timer stops when no live identity
  has `gps=1`.
- Adverts, contact export, and `SELF_INFO` use phone coordinates when GPS is
  enabled.
- No raw battery status, battery temperature, charging state, connectivity,
  pressure, ambient temperature, speed, or heading is added.
- No custom native platform channel or node-state schema migration is added.
- `./scripts/check.sh` passes; coverage does not regress; new files meet the
  80% line-coverage target.
- Documentation is updated, and hardware validation is reported honestly.

## 11. Handoff checklist

1. Read `AGENTS.md`, `README.md`, `DEVELOPMENT.md`, and `SECURITY.md`.
2. Run `git status`; leave unrelated work alone.
3. Implement in the order above: protocol → mesh_node → companion_server →
   app services → Android/UI → docs.
4. Keep core packages free of Flutter/Android imports.
5. Add tests with each behavior; do not defer them to the end.
6. Run `./scripts/check.sh`.
7. Run `./scripts/coverage.sh`; update the baseline only for legitimate new
   files.
8. Review `git diff` for unrelated changes, debug code, and accidental
   dependency upgrades.
9. Report:
   - what changed;
   - what tests/commands passed;
   - what was hardware-tested, on which Android versions/devices;
   - what remains unvalidated (background GPS is the main one).
10. Do not commit unless Jason explicitly asks.

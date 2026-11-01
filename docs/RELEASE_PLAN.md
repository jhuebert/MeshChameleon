# MeshChameleon 1.0.0 release plan

Status: **in progress**. Battery settings, version bumping and the changelog,
CI, the manual release workflow, two-key signing, and in-app backup/restore are
implemented. A signed `0.2.0` pre-release is published on GitHub Releases as the
tester channel; the `release` environment and signing secrets are configured.
Demo mode, the privacy/licenses work, signing fail-fast and the committed app
lockfile, store assets, and the Play Console account/listing/testing remain.

This plan takes MeshChameleon from the signed `0.2.0` pre-release and the
`0.1.0` storage baseline to a signed, tested, store-listed **1.0.0** release on
Google Play, with matching GitHub Releases. It assumes the app remains free,
open source, Android-only, and without ads, in-app purchases, analytics, or
telemetry.

**Critical path:** harden the product (backup/restore, demo + echo peer, policy
fixes) → set up signing, CI, and the release workflow → prepare store assets and
listing copy → run hardware/manual validation → **create the replacement Play
account and Play Console setup last** → complete the 12-tester/14-day closed test
→ production review and staged rollout. For a new personal account, expect
roughly 6–10 weeks of calendar time, with the final 3–5 weeks dependent on
Google’s verification and the closed test. An organization account could remove
the 14-day gate but requires a D-U-N-S number. The plan is quality-gated, not
date-gated.

All engineering, signing, asset, and validation work is intentionally
front-loaded. The Play account is only needed for the final package-name check,
Play App Signing enrollment, listing/declarations, testing tracks, and
production rollout.

## Decisions already made

| Item | Decision |
|---|---|
| Play developer account | The previous account was permanently closed for inactivity on 2024-03-14. A new account is required; the old fee is not refunded. |
| Application ID | `org.huebert.meshchameleon`; the `huebert.org` domain is owned, so the reverse-domain ID is under our control (no GitHub-namespace fallback). |
| Validation device | Pixel 7 on the latest Android release (Android 16 at the time of writing); older Android versions and the 16 KB page-size check in emulators |
| Primary release channel | Google Play production, free app |
| Distribution | Google Play + GitHub Releases (APK/AAB) |
| Play App Signing | Yes; we provide the app signing key (also used for GitHub APKs) and keep a separate upload key. Google holds a copy of the app signing key. |
| Play upload automation | First upload manual; optional CI upload later |
| GitHub APK signing | Signed with the app signing key so sideloaded installs can update in place from Play |
| Release workflow trigger | Manual `workflow_dispatch` |
| Release versioning | Workflow bumps, commits, tags, and builds |
| Battery optimization | Open Android settings; remove `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` |
| Telemetry | None |
| Privacy policy | A public file in this GitHub repo; linked from the listing and inside the app |
| Demo mode | Production-visible simulated radio **plus an echo peer** |
| Feature scope | Prefer features the official MeshCore client cannot provide; add in-app parity where users reasonably expect it (for example backup/restore) |
| Backups | In-app encrypted backup/restore from a single file; client identity export/import stays available |
| Store graphics | Fresh screenshots + branded feature graphic from existing assets |
| Assumed listing defaults | Tools, 13+, all countries, English (US), phone screenshots for 1.0; confirm in Phase 0 |
| Target date | None; quality-gated |

## Current baseline and gaps

Verified against the repository on 2026-11-01:

- The old Google Play developer account was permanently closed for inactivity
  on 2024-03-14. It cannot be reactivated. A new account, a new US$25
  registration fee, and fresh identity/device verification are required.
- No MeshChameleon app was published under the old account, so there is no
  store listing, review history, Play App Signing key, or user data to recover.
  A Play Store lookup returns 404 for `org.huebert.meshchameleon`, so no
  published app uses it; an unpublished reservation is still possible, so
  availability is checked in the new account before the first upload.
- Flutter 3.47.7 / Dart 3.13.5; Android `compileSdk 36`, `targetSdk 36`,
  `minSdk 24`; Java 17 target; AGP 9.1.0; Gradle 9.3.1.
- App version `0.2.0+1`; `productVersion` in `mesh_protocol` must stay in sync
  with `app/pubspec.yaml` (there is a test for this).
- Repository is public and MIT-licensed. CI and the manual release workflow are
  configured; the `release` environment holds the signing secrets. `main` is not
  protected.
- The signed `0.2.0` pre-release is published on GitHub Releases. Its APKs use
  the app signing key and its AAB uses the upload key, so sideloaded installs
  can later update in place from Play.
- No in-app privacy policy, open-source license page, source link, or
  “not affiliated with MeshCore” disclaimer.
- The simulated companion is available in release builds. It is still labeled
  **Simulated** and has no echo peer or demo banner, so Play reviewers can start
  the proxy but cannot exercise a full message exchange without hardware.
- `app/pubspec.lock` is git-ignored, so app dependency resolution is not locked.
- Release builds fall back to the debug signing key when `key.properties` is
  missing.
- User-guide screenshots are 860×1864 (2.17:1), over Play’s 2:1 maximum, and the
  home screenshot shows “disconnected / proxy stopped.”
- The hardware validation matrix is still documented as pending. Only one phone
  (a Pixel 7 on the latest Android release) and one companion are currently
  available; RF peer tests will be marked “not covered” unless a second
  radio/repeater is added.

## Play requirements checked for this plan

As of October 2026:

- New apps and updates must target Android 16 (API 36); the project already does.
- Apps with native code must support 16 KB page sizes. Flutter 3.47 should, but
  verify the built AAB/APKs before upload.
- New apps must use Play App Signing and upload an Android App Bundle (AAB).
- A privacy policy is required in the store listing **and within the app**.
- Apps targeting Android 14+ must declare foreground-service types in Play
  Console. MeshChameleon uses `connectedDevice`.
- Data safety, content rating, target audience, ads, app access, and export
  compliance declarations are required.
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is a restricted permission. The plan
  removes it and uses the policy-safe settings intent instead.
- Personal developer accounts created on or after 2023-11-13 must run a closed
  test with at least 12 testers opted in continuously for 14 days before
  production access. A replacement account created now is a new personal
  account, so this plan assumes the 12-tester path. An organization account
  (D-U-N-S verified) would not have that gate, but is not recommended unless
  there is already a registered business.
- New accounts must complete identity verification, contact verification, and
  device verification through the Play Console mobile app. Play apps must also
  be registered for Android developer verification; check the package
  registration status after creating the app.

## Phase 0 — Non-Play decisions and inputs

**Effort: 1 day. Blocking: yes. No Play account is created in this phase.**

1. Decide, for later, whether the replacement account will be **personal** or
   **organization**:
   - personal: simpler, US$25 fee, legal name/country/developer email shown on
     Play, and the 12-tester/14-day closed test applies;
   - organization: requires a D-U-N-S number and organization documents, avoids
     the 12-tester gate, and shows the organization name. Only worth it if a
     registered business already exists.
2. Confirm the public contact email and developer identity approach. For a
   personal account, Google displays the legal name, country, and developer email
   on Play; confirm that is acceptable before registration.
3. Confirm the hardware details for validation:
   - phone: Pixel 7 kept on the latest Android release (Android 16 at the time
     of writing); older Android versions are emulator-only;
   - companion model, firmware version, and BLE/TCP support;
   - whether a second radio/repeater can be borrowed for RF tests.
4. Build the tester prospect list. The 12-tester gate applies to a new personal
   account, so line up at least 15 people before creating the account. Demo mode
   makes it possible for testers without a radio to participate, but at least a
   few testers should have real hardware. Do not send Play opt-in instructions
   until the account and closed track exist.
5. Confirm the listing defaults: Tools, 13+, all countries, English (US),
   phone-only screenshots for 1.0, keep the MeshChameleon name, and add the
   “not affiliated with MeshCore” disclaimer.
6. Package name is confirmed as `org.huebert.meshchameleon`. The `huebert.org`
   domain is owned, so the reverse-domain ID is under our control and there is
   no GitHub-namespace fallback. A Play Store lookup currently returns 404;
   confirm availability once in Phase 5.
7. Record the inputs; no rename is planned unless Play reports the ID is taken.

**Deliverable:** a short `docs/RELEASE_INPUTS.md` (or a checklist comment in the
release issue) recording the account type, contact email, hardware, tester
prospects, package name, and listing defaults.

## Phase 1 — Product hardening for 1.0

**Effort: 2–3 weeks. Blocking: yes.**

### 1.1 Production demo mode with echo peer

Goal: a Play reviewer, a new user, or a tester without a radio can connect a real
MeshCore client to MeshChameleon and exercise the companion flow, with no RF.

- The simulated companion is exposed in release builds. Still to do: rename the
  tab to **Demo** or **Demo radio** and make the simulated nature unmistakable.
- Add a persistent visible label/banner: “Demo mode — no radio traffic.”
- Reuse the in-process `FakeRadioBus` and `MeshNode` simulator to run a second
  virtual node as an **echo peer**:
  - the peer has an ephemeral demo identity and a clear name (for example
    `Demo Echo`);
  - it responds to direct messages with a deterministic reply;
  - it can send a welcome advert or be seeded as a contact so the client can
    find it;
  - it never touches BLE, TCP, or real RF.
- Keep demo state in memory only; do not write demo contacts/messages into the
  user’s identity state.
- Make the demo work with the normal proxy: the MeshCore client, normally on the
  same phone at `127.0.0.1`, connects to the proxy port and sees the virtual
  companion.
- Add tests:
  - widget test for the Demo tab and warning label;
  - full-stack TCP test: MeshCore client → proxy → simulated radio → echo peer →
    reply;
  - test that demo mode works with no Bluetooth permissions and no network.
- Play review instructions will say: “Open Device link → Demo → Connect demo
  radio → start the proxy; connect your MeshCore client on the same phone to
  `127.0.0.1` and the proxy port (or use the phone’s local IP from another
  device). Messages stay on the phone.”

**Fallback:** if the echo peer cannot be made reliable quickly, ship the
simulated radio alone and keep the echo peer as a 1.0.x follow-up. Do not block
1.0 on a complex demo feature.

### 1.2 Backup and restore

Goal: a user can tap **Back up**, save one file, and later restore everything
without reading a guide. This is a normal app action, not a developer tool.

- Put **Backup & restore** on the home screen as a plain list item.
- Export flow:
  1. tap **Back up**;
  2. choose a passphrase (show/hide, confirmation, minimum length);
  3. pick a location with Android's file picker;
  4. done: `meshchameleon-YYYY-MM-DD.mcbackup` saved.
- Import flow:
  1. tap **Restore**;
  2. pick the file;
  3. enter the passphrase;
  4. show a plain summary (identities, contacts, channels, messages) and ask
     **Replace local data** or Cancel;
  5. confirm, restore, reload.
- The file contains the identity catalog, each identity's key and node state,
  network connection history, and session config. Exclude logs, diagnostics, and
  the attached radio's identity (it is not stored).
- Format: a small JSON envelope (format id, version, creation time, app and
  schema versions) around AES-256-GCM ciphertext. Derive the key with
  PBKDF2-HMAC-SHA256 (high iteration count, random salt); use a random nonce and
  authenticate the header. No custom extensions or manual key handling.
- Import validates the envelope, version, schema, and key/public-key match;
  refuses unknown future versions; writes atomically with a recovery copy; and
  reloads app state. Cap the file size.
- Never log or store the passphrase. Warn once, in plain language, that the file
  contains private identity keys and must be kept safe.
- Tests: round-trip, wrong passphrase, tampered ciphertext, corrupt JSON, future
  version, duplicate keys, missing secure-storage key, and a 0.1.0 fixture.
- Acceptance: a new user can complete both flows from the labels and prompts
  alone; no documentation is required.

### 1.3 Battery optimization policy fix

- Remove `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` from `AndroidManifest.xml`.
- Change the home-screen action from a direct exemption request to
  `FlutterForegroundTask.openIgnoreBatteryOptimizationSettings()`.
- Update the label/helper text to explain that the user must find MeshChameleon
  in the Android battery settings and choose “Unrestricted”/“Don’t optimize.”
- Keep `isIgnoringBatteryOptimizations()` for status display.
- Update the README, user guide, security notes, and diagnostics wording.
- Test on the Pixel 7’s latest Android release and on Android 7, 13, and 15
  emulators, including the settings round-trip and return-to-app refresh.

### 1.4 In-app privacy, licenses, and trust disclosures

- Add `PRIVACY.md` at the repository root as the canonical policy. Link it from
  Play as `https://github.com/jhuebert/MeshChameleon/blob/main/PRIVACY.md`.
- Add an in-app **Privacy** screen that shows the policy (or a complete summary
  plus a link to the full text) so the requirement is met even offline.
- If Play review objects to the GitHub blob URL, enable GitHub Pages for the
  same file and update the listing URL; keep the in-app text unchanged.
- Add **Open source licenses** using Flutter’s license page plus the app’s MIT
  license and third-party attributions.
- Add links to:
  - the user guide;
  - the GitHub repository;
  - the issue tracker;
  - the privacy policy.
- Add a clear **“Not affiliated with the MeshCore project”** disclaimer on the
  About/Information screen and in the store listing.
- Add a prominent trusted-network warning when the proxy is started:
  - the local endpoint is plaintext and unauthenticated;
  - anyone who can reach the port can use the session and export/import the
    virtual identity;
  - do not expose it beyond a trusted LAN.
- Ensure no private key material appears in logs or copied diagnostics.

### 1.5 Signing fail-fast and dependency locking

- Change the Android release build so it **fails** when `key.properties` is
  missing instead of silently using the debug key. Keep debug builds working
  normally.
- Update `key.properties.example` to recommend RSA 4096 and document the CI
  environment-variable path.
- Commit `app/pubspec.lock` (add a `.gitignore` exception). Keep package
  lockfiles ignored if they are libraries, but the app lockfile is part of the
  release.
- Pin the Flutter version in CI and document the expected SDK.
- Add a release check that the built APK/AAB is not signed with the Android
  debug certificate.

### 1.6 Versioning and changelog

- Add `scripts/bump_version.sh` that updates:
  - `app/pubspec.yaml` (`X.Y.Z+N`);
  - `packages/mesh_protocol/lib/src/constants.dart` (`productVersion`);
  - `packages/mesh_protocol/lib/src/models.dart` (`DeviceInfo.version` default);
  - `docs/USER_GUIDE.md` version line;
  - `CHANGELOG.md`.
- Refactor tests that hardcode `0.1.0` (for example `home_screen_test.dart`) to
  use `productVersion` or explicit fixtures, so a release bump does not require
  editing tests by hand.
- Add `CHANGELOG.md` with a 1.0.0 entry using Keep a Changelog style.
- Version rules:
  - first Play upload: `1.0.0+1`;
  - every subsequent Play upload, including test-track fixes, must increase the
    build number;
  - GitHub APKs may show ABI-adjusted version codes; document this.
- Update README, user guide, DEVELOPMENT, SECURITY, AGENTS, and ATTRIBUTION for
  1.0.0 and the new features.

## Phase 2 — Release engineering

**Effort: 3–5 days. Blocking: yes.**

### 2.1 Signing keys

No MeshChameleon app was ever uploaded under the closed account, so there is no
old Play App Signing key to recover. Create two fresh keys:

- **App signing key** (`meshchameleon-app-signing.p12`) — signs the GitHub
  release APKs and is uploaded to Play at enrollment as the app signing key, so
  sideloaded installs can update in place from Play.
- **Upload key** (`meshchameleon-upload.p12`) — signs the AAB that is uploaded
  to Play. If it is lost, request an upload-key reset; users are unaffected.

Keep the keys different. The app signing key is the long-lived one: back it up
carefully. Play keeps a copy after enrollment, but you still need it to sign
future GitHub APKs.

Generate locally (do not commit, do not send the files or passwords to anyone):

```sh
mkdir -p ~/keystores
keytool -genkeypair -v \
  -keystore ~/keystores/meshchameleon-app-signing.p12 \
  -storetype PKCS12 \
  -keyalg RSA \
  -keysize 4096 \
  -validity 10000 \
  -alias app-signing \
  -dname "CN=MeshChameleon App Signing, OU=MeshChameleon, O=MeshChameleon"

keytool -genkeypair -v \
  -keystore ~/keystores/meshchameleon-upload.p12 \
  -storetype PKCS12 \
  -keyalg RSA \
  -keysize 4096 \
  -validity 10000 \
  -alias upload \
  -dname "CN=MeshChameleon Upload, OU=MeshChameleon, O=MeshChameleon"
```

Then:

1. Record both SHA-256 fingerprints (they are public).
2. Store both `.p12` files and passwords in a password manager and an offline
   encrypted backup.
3. Create `app/android/key.properties` locally for the **upload** key:
   ```properties
   storePassword=...
   keyPassword=...
   keyAlias=upload
   storeFile=/absolute/path/to/meshchameleon-upload.p12
   ```
4. Build a signed APK/AAB and verify the signer locally:
   ```sh
   apksigner verify --print-certs app/build/app/outputs/flutter-apk/app-release.apk
   ```
5. Do not enroll in Play App Signing yet; Phase 5.2 uploads the app signing key
   through the Play PEPK flow.

### 2.2 GitHub environments and secrets

Create a protected `release` environment with required reviewer approval
(Jason) and deployments restricted to `main`. Add:

| Secret | Purpose |
|---|---|
| `UPLOAD_KEYSTORE_BASE64` | Base64 of `meshchameleon-upload.p12` |
| `UPLOAD_KEYSTORE_PASSWORD` | Upload keystore password |
| `UPLOAD_KEY_ALIAS` | `upload` |
| `UPLOAD_KEY_PASSWORD` | Upload key password |
| `APP_SIGNING_KEYSTORE_BASE64` | Base64 of `meshchameleon-app-signing.p12` |
| `APP_SIGNING_KEYSTORE_PASSWORD` | App signing keystore password |
| `APP_SIGNING_KEY_ALIAS` | `app-signing` |
| `APP_SIGNING_KEY_PASSWORD` | App signing key password |

Use `gh secret set --env release` from files so the base64 never enters shell
history. The workflow decodes both keystores into `$RUNNER_TEMP`, writes
`key.properties` for the upload key, re-signs the APKs with the app signing key,
and deletes both in an `always()` step.

### 2.3 CI workflow

Add `.github/workflows/ci.yml`:

- triggers: `pull_request`, `push` to `main`;
- `permissions: contents: read`;
- `concurrency` to cancel superseded runs;
- Flutter 3.47.7, Temurin Java 17, Gradle cache;
- run `scripts/check.sh`;
- run `scripts/check_store_assets.sh` once it exists;
- run a lockfile check (`flutter pub get` must not change the committed
  `app/pubspec.lock`);
- optionally build a debug APK to catch Android build breaks;
- pin third-party actions to full commit SHAs and avoid `pull_request_target`
  with secrets;
- no signing secrets in PR jobs.

After CI is stable, protect `main`: require the check, disallow force pushes,
and keep the release workflow’s fast-forward path in mind.

### 2.4 Manual release workflow

Add `.github/workflows/release.yml` with `workflow_dispatch` inputs:

| Input | Notes |
|---|---|
| `version` | Semver without `v`, e.g. `1.0.0` |
| `build_number` | Integer; must be higher than the last Play upload |
| `release_notes` | Multiline notes for `CHANGELOG.md` and the GitHub Release |
| `prerelease` | Mark the GitHub Release as a pre-release (RC/beta) |
| `dry_run` | Build and verify without committing, tagging, or publishing |

Recommended execution (avoids committing a broken build):

1. Validate inputs; check out `main`; require a clean tree; ensure
   `v<version>` does not exist.
2. Create a temporary `release/v<version>` branch.
3. Run `scripts/bump_version.sh <version> <build_number> <notes-file>` to
   update every version and add the release notes to `CHANGELOG.md`.
4. Run `scripts/check.sh`.
5. Build the AAB, universal APK, and split APKs via `scripts/build.sh` (upload
   key), then re-sign the APKs with the app signing key; set `SOURCE_DATE_EPOCH`
   from the release commit and `MESHCHAMELEON_GIT_DIRTY=0`.
6. Verify:
   - the AAB is signed with the upload key and the APKs with the app signing
     key, not the debug key;
   - the AAB and universal APK `versionCode`/`versionName` match the inputs
     (split APKs may use Flutter’s ABI-adjusted version codes);
   - 16 KB page-size alignment on 64-bit native libraries;
   - SHA-256 checksums;
   - `scripts/check_store_assets.sh`.
7. If `dry_run`, upload artifacts to the workflow run and stop.
8. Abort if `main` has moved since the release branch was created. Otherwise
   fast-forward `main` to the release branch commit and push; create and push
   tag `v<version>`; delete the temporary branch.
9. Create the GitHub Release from the tag with the notes and attach:
   - `MeshChameleon-<version>.aab`;
   - `MeshChameleon-<version>-universal.apk`;
   - per-ABI APKs (`arm64-v8a`, `armeabi-v7a`, `x86_64`);
   - `SHA256SUMS.txt`;
   - `build-metadata.txt` (version, commit, build time, Flutter version);
   - optionally a `release-notes.md`.
10. Do **not** upload to Play in this workflow for 1.0; upload manually.
11. For 1.0, exercise the workflow with `dry_run=true`. Do not publish the
    final `v1.0.0` GitHub Release until Phase 5 confirms the package is
    available in Play Console.
12. Do not attach debug-signed APKs to public releases. Testers use the release
    APKs signed with the app signing key; debug builds use a machine-local
    certificate and cannot migrate to Play.

Branch protection note: the default `GITHUB_TOKEN` cannot push to a protected
`main` without a bypass. Because `main` is currently unprotected, the workflow
can use `contents: write`. If branch protection is enabled before 1.0, either
add the release actor as a bypass or switch to a release PR/fast-forward design.
Document the chosen policy in `docs/RELEASING.md`.

### 2.5 Release documentation

Add:

- `docs/RELEASING.md` — keystore generation, secrets, workflow inputs, artifact
  verification, Play upload, version rules, rollback.
- `docs/PLAY_STORE.md` — exact listing copy, screenshots/alt text, declaration
  answers, reviewer instructions.
- `docs/HARDWARE_VALIDATION.md` — the matrix and recorded results.
- `CHANGELOG.md`.
- `PRIVACY.md`.
- `docs/STORE_ASSETS.md` — capture and export instructions.

## Phase 3 — Store listing and graphics

**Effort: 3–5 days. Blocking: yes.**

### 3.1 Assets

| Asset | Requirement | Source |
|---|---|---|
| App icon | 512×512, 32-bit PNG | Downscale `app/assets/branding/icon.png` |
| Feature graphic | 1024×500, 24-bit PNG or JPEG, no alpha | Brand background + icon + wordmark + tagline |
| Phone screenshots | 2–8, 1080×2160 (or another ≤2:1 size), 24-bit PNG, no alpha | Fresh captures from demo mode |
| Tablet screenshots | Optional for 1.0 | Defer |

Screenshot set (capture with demo mode and sample identities):

1. Home with demo radio connected, proxy running, battery card visible.
2. Device link / Demo mode explanation.
3. Identities with several sample identities.
4. Identity creation or identity detail.
5. Information/diagnostics with version and link stats.
6. Logs or proxy/trusted-network warning.

Current 860×1864 images must be re-exported or re-captured; they exceed the 2:1
ratio. Prefer fresh 1080×2160 captures. Keep one master copy in
`docs/screenshots/` and use it for both the user guide and Play; add a release
checklist item to recapture after UI changes.

Add `scripts/store_assets.sh` and `scripts/check_store_assets.sh` so the icon,
feature graphic, screenshot count, dimensions, alpha channel, and aspect ratio
are validated in CI.

### 3.2 Listing copy

Draft in `docs/PLAY_STORE.md`:

- **Title:** MeshChameleon
- **Short description:** “Turn your Android phone into a MeshCore companion.”
- **Full description:** explain what it is, what it is not, requirements,
  features, demo mode, privacy, open source, and the MeshCore disclaimer.
- **Category:** Tools.
- **Tags:** MeshCore, mesh radio, companion, off-grid, Bluetooth, LoRa (use only
  accurate terms).
- **Contact:** public developer name, email, GitHub repo, privacy policy.
- **App access:** no login; demo instructions; hardware requirement for real
  mesh use.
- **Release notes:** 500 characters or fewer for Play.
- **Alt text:** unique description for every screenshot.
- **Optional demo video:** an unlisted YouTube walkthrough is useful for Play
  app access, the README, and reviewers who cannot install the demo.

Important wording:

- “MeshChameleon is not a messaging app. It is a local companion-protocol bridge
  for your existing MeshCore client.”
- “Requires a MeshCore companion radio for real mesh use.”
- “The TCP companion endpoint is unencrypted and has no password. Keep it on the
  phone or a trusted network, and do not expose it to the internet.”
- “No analytics, no cloud service, no telemetry.”
- “Open source (MIT). Not affiliated with the MeshCore project.”

### 3.3 Defer Play Console work

Play account creation, app creation, listing upload, declarations, and testing
tracks are deliberately deferred to **Phase 5**. Prepare `docs/PLAY_STORE.md`
and all assets now so Phase 5 is mostly data entry and verification.

## Phase 4 — Validation and release gates

**Effort: 1–2 weeks. Blocking: yes.**

### 4.1 Automated checks

- `scripts/check.sh` passes for every package and the app.
- `flutter analyze` and all tests pass on the release commit.
- Store asset validation passes.
- Lockfile is unchanged after `flutter pub get`.
- AAB is signed with the upload key and the GitHub APKs with the app signing
  key; neither is the debug certificate.
- `versionCode` is at least 1 and greater than any prior Play upload;
  `versionName` matches.
- 16 KB page-size check passes for arm64-v8a and x86_64.
- Install the release-signed APK on a clean device/emulator.
- A GitHub-signed APK updates in place to a Play-equivalent build with a higher
  versionCode, with app data intact.

### 4.2 Hardware validation

Record exact device, Android version, firmware, commit, and result in
`docs/HARDWARE_VALIDATION.md`. With one phone (Pixel 7 on the latest Android
release) plus one companion, run:

- BLE scan/identify/battery;
- identity switch and resume;
- BLE UI test with a background interval;
- reconnect test (radio reboot);
- BLE mesh test with `DO_TX=false` (RX/scan only);
- TCP lifecycle test if the companion supports TCP.

The following require a second radio/repeater and will be marked **not covered**
until one is available:

- `android_ble_rf_test` (RF direct message);
- `multi_identity_live_test` (RF direct messages);
- `repeater_validation_test`;
- channel/group RF tests.

Do not describe the release as “hardware validated” beyond what was actually
run. The demo echo peer is not a substitute for RF validation.

### 4.3 Manual QA matrix

- Fresh install with no permissions; grant/deny Bluetooth, notifications, and
  location (Android ≤11).
- Demo mode with no radio, no Bluetooth permission, airplane mode.
- Real BLE link and TCP link; connect, disconnect, reconnect, radio reboot.
- Proxy start/stop, port change, client connect, multiple identities.
- Background: screen off, app backgrounded, Doze, battery settings round-trip,
  notification permission denied, OEM battery manager.
- Backup/restore: export, restore on a clean install, wrong passphrase, corrupt
  file, replace over existing data, and a 0.1.0 fixture.
- Identity portability: export the active identity key with a MeshCore client,
  uninstall, reinstall, and import it; verify the key matches.
- Upgrade path: install the GitHub release APK, create data, then install a
  build signed with the app signing key and a higher versionCode (simulating
  Play); verify identities, contacts, channels, and messages survive.
- Release-signed APK: clean install, then upgrade from an earlier release-signed
  build to a higher build number; verify data survives. Repeat from the Play
  internal track in Phase 5.4.
- The Pixel 7’s latest Android release; Android 7.0/7.1, 13, and 15 on emulators
  (no second phone); 16 KB page-size emulator; edge-to-edge; dark/light; large
  font; TalkBack basics; tablet/foldable smoke test.
- No private keys in logs or copied diagnostics.
- App size and startup time are reasonable.

### 4.4 Play policy audit

- Privacy policy URL ready for the listing **and** the policy present in app.
- Data safety answers match actual behavior (no collection/sharing).
- Foreground-service declaration matches the manifest.
- No restricted battery permission.
- Bluetooth/location permissions explained in the listing and policy.
- App access instructions are complete and testable.
- “Not a messaging app / requires hardware / not affiliated with MeshCore”
  wording is present.
- Export compliance answered and documented.
- Content rating and target audience are consistent.
- No misleading “works without a radio” claims; demo mode is clearly labeled.

## Phase 5 — Create the Play account and set up Play Console

**Effort: 1–3 days of work plus Google verification; blocking: yes. This is
deliberately the last setup phase, after the app, signing, assets, and validation
are ready.**

### 5.1 Create the replacement developer account

1. Create a fresh Google account/email for the project if possible. The old
   closed developer account cannot be reactivated; a fresh account avoids signup
   conflicts and keeps the project identity separate. The legal name and payment
   profile must still match Jason’s real identity.
2. Register at <https://play.google.com/console/signup>:
   - accept the Developer Distribution Agreement;
   - pay the one-time US$25 registration fee (the old fee is not refunded);
   - choose personal or organization;
   - complete identity verification with a government ID;
   - verify the contact email and phone;
   - complete device verification in the Play Console mobile app;
   - enable two-step verification.
3. Do not leave the new account idle after creation. Move directly into app
   creation and internal testing; an account with no submitted app can be closed
   again for inactivity after a year.

### 5.2 Create the app and reserve the package name

1. Create the app:
   - name, package `org.huebert.meshchameleon`, default language English (US);
   - app (not game), free;
   - accept the developer program and Play App Signing terms.
2. If Play says the package is unavailable, choose another `org.huebert.*` ID
   **before any upload**:
   - update `applicationId`, `namespace`, and the `MainActivity` package/path;
   - rebuild and rerun the Phase 4 release checks;
   - users can back up in the old build and restore in the renamed build; the
     client’s identity export/import also still works.
3. Confirm the **Android developer verification / package registration** status
   for the app is complete, or complete the manual registration flow.
4. Enroll in **Play App Signing** when creating the app. Choose **Use a
   different key** and upload `meshchameleon-app-signing.p12` with the PEPK
   tool. Register the upload key when prompted. Save both certificate
   fingerprints; Play now signs the distributed APKs with the same app signing
   key that signs the GitHub APKs, so users can update in place.
5. Upload the first signed AAB to **Internal testing** and verify the Play App
   Signing certificate matches the app signing key.

### 5.3 Complete the listing and declarations

Complete **App content**:

- privacy policy URL;
- ads: no;
- app access: demo instructions + hardware note;
- content rating questionnaire: expected Everyone;
- target audience: 13+;
- data safety: no collection/sharing, data processed locally;
- government/financial/health/news: no;
- foreground service: `connectedDevice`, with the radio-link explanation;
- export compliance: declare encryption use; document the
  publicly-available/mass-market position;
- account deletion: not applicable (no accounts).

Complete **Store listing** with the Phase 3 assets and copy.

### 5.4 Internal and closed testing

1. Install the GitHub release APK on a clean device, create data, then install
   the internal-test build with a higher build number without uninstalling;
   verify the data survives and Play App Signing uses the app signing key. Test
   backup and restore.
2. Prepare `docs/TESTER_GUIDE.md` with the opt-in link, the signed GitHub
   release APK as the pre-Play build, demo-mode instructions for testers without
   radios, the 14-day expectation, and a short feedback template.
3. Add the tester list and run **Closed testing** with 12+ testers opted in
   continuously for 14 days. Keep at least 15 testers invited to cover dropouts.
4. Collect feedback, fix issues, and upload fixes with higher version codes.
5. Apply for production access after the 14-day window and all testers are still
   opted in.

## Phase 6 — Launch and post-launch

**Effort: about 1 week after production access is granted, plus monitoring.**

1. Confirm the final package ID and that Play internal/closed testing passed. If
   the package ID had to change, rebuild and rerun the Phase 4 checks.
2. Merge the final release prep to `main`; run CI.
3. Run the manual release workflow with the version/build number that passed Play
   testing (for example `1.0.0` and `2` if fixes were uploaded); verify the
   GitHub Release, signatures, checksums, and artifacts.
4. Confirm production access was granted (apply if not already done); wait for
   review (typically 1–7 days, longer if issues).
5. Start a staged production rollout at 10%; monitor Android vitals, crash/ANR
   reports, reviews, and GitHub issues; increase to 50% then 100%.
6. Update README and user guide with the Play link and 1.0.0 status.
7. Announce the release (optional).
8. For the first two weeks, triage issues daily. Patch releases use the same
   workflow with `1.0.1+2`, etc.
9. Keep screenshots, listing copy, privacy policy, and hardware validation
   current for every release.

## Post-1.0 backlog

These are explicitly out of scope for 1.0 unless a release blocker forces them:

- Android 17 `ACCESS_LOCAL_NETWORK` runtime permission when Flutter moves the
  default target to API 37.
- Boot resume (shape B: engine in the foreground-task isolate) so the proxy can
  return after a reboot without opening the app.
- Encrypt `node_state.json` at rest and add a biometric/device-credential gate.
- Tablet/Chromebook screenshots and large-screen layout polish.
- Localization beyond English.
- Optional opt-in crash reporting, if Play vitals and user diagnostics are not
  enough.
- F-Droid or other FOSS store submission.
- A richer demo mesh (seeded contacts/channels, multiple peers).

## Definition of done for 1.0.0

- [ ] New Play account created and verified; package
      `org.huebert.meshchameleon` reserved; developer verification/registration
      confirmed; required testing path known.
- [ ] Contact email and listing identity confirmed.
- [ ] Demo mode + echo peer works with a real MeshCore client over TCP.
- [ ] In-app backup/restore round-trips, and a GitHub-signed APK upgrades in
      place to a Play-signed build with app data intact.
- [ ] Play App Signing uses the app signing key, and the client’s identity
      export/import still works.
- [ ] Battery settings flow works; restricted permission removed.
- [ ] In-app privacy policy, licenses, source link, and disclaimer present.
- [ ] `app/pubspec.lock` committed; release signing fails without a keystore.
- [ ] CI and manual release workflows pass; signed artifacts verified.
- [ ] Store icon, feature graphic, and 2:1-compliant screenshots ready.
- [ ] Play listing, Data safety, content rating, FGS, and export declarations
      complete.
- [ ] Hardware matrix recorded honestly; RF gaps marked not covered.
- [ ] Internal testing passed; closed testing completed if required.
- [ ] Production rollout started and monitored.
- [ ] GitHub Release `v1.0.0` published with AAB, APKs, and checksums.
- [ ] README/user guide updated with the Play link.

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| New personal account is subject to the 12-tester gate | 14-day closed test becomes the critical path | Recruit 15 testers; demo mode lowers the hardware barrier; organization account only if a business already exists |
| New account is closed again for inactivity | Lose the new US$25 fee and start over | Verify contact details and upload a signed AAB to internal testing early; keep Play Console active |
| `org.huebert.meshchameleon` is unavailable in the new account | Rework before the first upload | Check immediately after creating the app; if Play reports it taken, pick another `org.huebert.*` ID and update namespace/MainActivity/build config before signing |
| Personal account displays legal name and country | Privacy concern | Confirm before signup; use an organization account only if a registered business exists |
| Old Google account cannot be reused for signup | Setup delay | Use a fresh Google account/email for the project; the legal identity/payment profile can still be Jason’s |
| Play account detail or package rejection is discovered late | Rework at the end | Finish all non-Play work first; package lookup currently returns 404; if Play rejects the confirmed ID, pick another `org.huebert.*` ID and rerun the release checks |
| Play reviewer cannot test without hardware | Rejection for broken/limited functionality | Production demo mode + reviewer instructions + optional demo video |
| Restricted battery permission | Policy rejection | Remove permission; open settings instead |
| Privacy policy missing in app | Policy rejection | Add `PRIVACY.md` + in-app Privacy screen before submission |
| Screenshots over 2:1 or stale UI | Listing rejection/quality issues | Fresh 1080×2160 captures; asset validation in CI |
| Upload key lost | Cannot upload updates | Password manager + offline backup; Play upload-key reset; users are unaffected |
| Debug-signed release shipped | Cannot upload/upgrade | Fail release build without keystore; verify signer in CI |
| Debug-signed pre-release builds cannot migrate | Tester data loss | Testers use release APKs signed with the app signing key; debug builds stay developer-only |
| Play rejects or overrides the uploaded app signing key | No seamless GitHub → Play migration | Confirm the own-key option during enrollment; fall back to a Google-generated key and a documented one-time uninstall with backup/restore |
| App signing key leaked | Malicious updates that Android accepts | Protected release environment (required reviewer, `main`-only), 2FA, offline backup; rotate or contact Play support if compromised |
| 16 KB page-size violation | Upload blocked | Flutter 3.47 + verification + 16 KB emulator test |
| Foreground-service declaration mismatch | Policy rejection | Declare `connectedDevice` accurately; match manifest |
| Local endpoint is plaintext | Security/privacy review concern | Prominent trusted-network warning; policy disclosure; no internet exposure |
| Export compliance paperwork | Launch delay | Answer the Play questionnaire; document the encryption position; seek advice if needed |
| RF behavior not validated | Overclaiming/quality risk | Record matrix; mark RF tests not covered; borrow a peer radio if possible |
| No crash reporting | Slower production diagnosis | Rely on Play vitals + user diagnostics; consider opt-in crash reporting post-1.0 |
| Branch protection blocks release commit | Release workflow fails | Use a release bot bypass or switch to release PR/fast-forward; document before enabling protection |

## Open inputs

These are placeholders until confirmed:

- Personal vs organization account for the new registration.
- New Google account/email and public contact email (and whether a dedicated
  address will be created).
- Companion model/firmware and BLE/TCP support.
- Whether a second radio/repeater can be borrowed for RF tests.
- Tester list and recruitment plan.
- Confirmation of the Tools/13+/all-countries/phone-only defaults.
- Final app-name/disclaimer wording.
- Whether to add tablet screenshots after 1.0.

## Suggested order of work

1. Confirm the non-Play inputs (account type, contact email, companion hardware,
   testers, listing defaults); the phone and package name are already confirmed.
2. Build backup/restore — users expect it, and it protects data before Play.
3. Build demo mode + echo peer — it gates review and tester participation.
4. Remove the battery permission and add privacy/licenses/trust disclosures.
5. Lock dependencies, fail-fast signing, version bump tooling, CI.
6. Generate the app signing and upload keys, add secrets, and exercise the
   release workflow with `dry_run`.
7. Build store assets and write the listing copy/declarations.
8. Run hardware/manual validation; record results.
9. **Create the new Play account and Play Console setup last**; upload to
   internal testing, then run closed testing.
10. Produce the final GitHub Release and start the production rollout.

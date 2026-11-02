#!/usr/bin/env bash
# Build a release APK signed with the app signing key so it can update an
# existing GitHub release install in place.
#
# GitHub release APKs are signed with the app signing key. Gradle's local
# release builds use the upload key (or the debug key when
# app/android/key.properties is absent), so they cannot replace a release
# install. This script builds a normal release APK and then re-signs it with the
# app signing key, mirroring .github/workflows/release.yml.
#
# Usage:
#   scripts/build_test_apk.sh [--build-number N] [--install]
#                             [--device SERIAL] [--keystore PATH]
#                             [--alias ALIAS]
#
# Signing inputs:
#   MESHCHAMELEON_APP_SIGNING_KEYSTORE        app signing keystore path
#   MESHCHAMELEON_APP_SIGNING_ALIAS           default app-signing
#   MESHCHAMELEON_APP_SIGNING_STORE_PASSWORD  prompted when unset
#   MESHCHAMELEON_APP_SIGNING_KEY_PASSWORD    defaults to the store password
#   MESHCHAMELEON_APP_SIGNING_SHA256          expected certificate fingerprint
#
# The build number defaults to one higher than the installed version code when
# a single adb device is attached, otherwise one higher than the pubspec build
# number. Split APKs use Flutter's ABI-adjusted version codes, so the installed
# code can be much larger than the pubspec value.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

die() {
  echo "build_test_apk: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: scripts/build_test_apk.sh [options]

  --build-number N   Android version code (default: installed code + 1,
                     or pubspec build number + 1 when no phone is attached)
  --install          Install the signed APK with `adb install -r`
  --device SERIAL    Select an adb device when several are attached
  --keystore PATH    App signing keystore (required; can also be set with
                     MESHCHAMELEON_APP_SIGNING_KEYSTORE)
  --alias ALIAS      App signing key alias (default: app-signing)
  -h, --help         Show this help
EOF
}

build_number=""
install=0
device=""
keystore="${MESHCHAMELEON_APP_SIGNING_KEYSTORE:-}"
alias="${MESHCHAMELEON_APP_SIGNING_ALIAS:-app-signing}"
expected_sha="${MESHCHAMELEON_APP_SIGNING_SHA256:-47:F3:00:E4:82:06:EA:4B:B8:E3:85:76:70:C0:6F:E1:7B:4D:1A:96:2C:74:79:40:00:09:48:84:67:67:D5:5E}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-number)
      [[ $# -ge 2 ]] || { usage; die "--build-number requires a value"; }
      build_number="$2"
      shift 2
      ;;
    --install)
      install=1
      shift
      ;;
    --device)
      [[ $# -ge 2 ]] || { usage; die "--device requires a value"; }
      device="$2"
      shift 2
      ;;
    --keystore)
      [[ $# -ge 2 ]] || { usage; die "--keystore requires a value"; }
      keystore="$2"
      shift 2
      ;;
    --alias)
      [[ $# -ge 2 ]] || { usage; die "--alias requires a value"; }
      alias="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

if [[ -n "$build_number" && ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  die "invalid build number '$build_number'"
fi

[[ -n "$keystore" ]] ||
  die "pass --keystore PATH or set MESHCHAMELEON_APP_SIGNING_KEYSTORE"
[[ -f "$keystore" ]] || die "keystore not found: $keystore"
command -v keytool >/dev/null 2>&1 || die "keytool not found; install a JDK"

version_line="$(sed -n 's/^version:[[:space:]]*//p' app/pubspec.yaml | head -n1)"
version_name="${version_line%%+*}"
pubspec_build="${version_line##*+}"
[[ "$version_name" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "could not parse version name from app/pubspec.yaml"
[[ "$pubspec_build" =~ ^[1-9][0-9]*$ ]] ||
  die "could not parse build number from app/pubspec.yaml"

sdk_root() {
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -z "$sdk" && -f app/android/local.properties ]]; then
    sdk="$(sed -n 's/^sdk\.dir=//p' app/android/local.properties | head -n1)"
  fi
  printf '%s' "$sdk"
}

find_sdk_tool() {
  local name="$1" sdk tool
  sdk="$(sdk_root)"
  if [[ -n "$sdk" && -d "$sdk/build-tools" ]]; then
    tool="$(find "$sdk/build-tools" -mindepth 2 -maxdepth 2 -type f -name "$name" \
      2>/dev/null | sort -V | tail -n1)"
    if [[ -n "$tool" ]]; then
      printf '%s' "$tool"
      return 0
    fi
  fi
  command -v "$name"
}

find_adb() {
  local sdk
  sdk="$(sdk_root)"
  if [[ -n "$sdk" && -x "$sdk/platform-tools/adb" ]]; then
    printf '%s' "$sdk/platform-tools/adb"
    return 0
  fi
  command -v adb
}

aapt="$(find_sdk_tool aapt || true)"

adb_path="$(find_adb || true)"
if [[ -n "$device" && -z "$adb_path" ]]; then
  die "--device requires adb; install the Android SDK platform-tools"
fi

adb_cmd=()
if [[ -n "$adb_path" ]]; then
  if [[ -n "$device" ]]; then
    adb_cmd=("$adb_path" -s "$device")
  else
    mapfile -t online_devices < <(
      "$adb_path" devices | awk 'NR > 1 && $2 == "device" { print $1 }'
    )
    if ((${#online_devices[@]} == 1)); then
      device="${online_devices[0]}"
      adb_cmd=("$adb_path" -s "$device")
    elif ((${#online_devices[@]} > 1)); then
      echo "build_test_apk: multiple devices attached; use --device <serial>" >&2
    fi
  fi
fi

if ((install)) && ((${#adb_cmd[@]} == 0)); then
  die "--install requires a connected device (and --device when several are attached)"
fi

if [[ -z "${MESHCHAMELEON_APP_SIGNING_STORE_PASSWORD:-}" ]]; then
  [[ -t 0 ]] || die "set MESHCHAMELEON_APP_SIGNING_STORE_PASSWORD or run from a terminal"
  printf 'App signing keystore password: ' >&2
  IFS= read -r -s MESHCHAMELEON_APP_SIGNING_STORE_PASSWORD
  printf '\n' >&2
fi
[[ -n "$MESHCHAMELEON_APP_SIGNING_STORE_PASSWORD" ]] ||
  die "empty keystore password"
export MESHCHAMELEON_APP_SIGNING_STORE_PASSWORD
if [[ -z "${MESHCHAMELEON_APP_SIGNING_KEY_PASSWORD:-}" ]]; then
  MESHCHAMELEON_APP_SIGNING_KEY_PASSWORD="$MESHCHAMELEON_APP_SIGNING_STORE_PASSWORD"
fi
export MESHCHAMELEON_APP_SIGNING_KEY_PASSWORD

keystore_cert="$(
  keytool -list -v -keystore "$keystore" -alias "$alias" \
    -storepass:env MESHCHAMELEON_APP_SIGNING_STORE_PASSWORD \
    2>/dev/null |
    awk -F': ' '/SHA256:/ { gsub(/:/, "", $2); print tolower($2); exit }'
)"
[[ -n "$keystore_cert" ]] ||
  die "could not read alias '$alias' from $keystore (wrong password or alias?)"

expected_normalized="${expected_sha//:/}"
expected_normalized="${expected_normalized,,}"
[[ "$keystore_cert" == "$expected_normalized" ]] ||
  die "certificate $keystore_cert does not match the expected app signing key $expected_normalized"

installed_code=""
if ((${#adb_cmd[@]} > 0)); then
  installed_code="$(
    "${adb_cmd[@]}" shell dumpsys package org.huebert.meshchameleon 2>/dev/null |
      sed -n 's/.*versionCode=\([0-9][0-9]*\).*/\1/p' | head -n1 || true
  )"
fi

if [[ -z "$build_number" ]]; then
  build_number=$((pubspec_build + 1))
  if [[ -n "$installed_code" && "$installed_code" -ge "$build_number" ]]; then
    build_number=$((installed_code + 1))
  fi
fi
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || die "invalid build number '$build_number'"

echo "Building MeshChameleon $version_name (version code $build_number)" >&2
raw_apk="app/build/app/outputs/flutter-apk/app-release.apk"
rm -f "$raw_apk"
./scripts/build.sh apk --release --build-number "$build_number"

[[ -f "$raw_apk" ]] || die "build did not produce $raw_apk"

mkdir -p build/test-apk
out="build/test-apk/MeshChameleon-${version_name}-${build_number}-universal-test.apk"
rm -f "$out"
cp "$raw_apk" "$out"
APP_SIGNING_KEYSTORE_PASSWORD="$MESHCHAMELEON_APP_SIGNING_STORE_PASSWORD" \
  APP_SIGNING_KEY_PASSWORD="$MESHCHAMELEON_APP_SIGNING_KEY_PASSWORD" \
  ./scripts/sign_apks.sh \
  --keystore "$keystore" \
  --alias "$alias" \
  --expected-sha256 "$expected_normalized" \
  "$out"

if [[ -n "$aapt" ]]; then
  badging="$("$aapt" dump badging "$out" | sed -n '1p')"
  apk_code="$(sed -E "s/.*versionCode='([0-9]+)'.*/\1/" <<<"$badging")"
  apk_name="$(sed -E "s/.*versionName='([^']*)'.*/\1/" <<<"$badging")"
  [[ "$apk_code" == "$build_number" && "$apk_name" == "$version_name" ]] ||
    die "signed APK reports $apk_name ($apk_code), expected $version_name ($build_number)"
fi

(cd build/test-apk && sha256sum "$(basename "$out")" >SHA256SUMS.txt)

echo "Signed APK: $repo_root/$out" >&2
echo "versionName=$version_name versionCode=$build_number" >&2
echo "certificate SHA-256=$expected_normalized" >&2
if [[ -n "$installed_code" && "$installed_code" -ge 1000 ]]; then
  echo "Note: the installed split APK reports version code $installed_code;" >&2
  echo "this universal APK uses $build_number so it can update in place." >&2
fi
echo "Use a higher build number than any local test build when cutting an official release." >&2

if ((install)); then
  echo "Installing on $device..." >&2
  "${adb_cmd[@]}" install -r "$out"
fi

#!/usr/bin/env bash
# Re-sign APKs with the app signing key and verify the result.
#
# Shared by the release workflow, the test-build workflow, and
# scripts/build_test_apk.sh so the signing procedure is defined once.
#
# Usage:
#   scripts/sign_apks.sh --keystore PATH --alias ALIAS [--expected-sha256 HEX] APK...
#
# Each APK is signed in place. The script verifies the signed certificate and
# zip alignment. Passwords are read from APP_SIGNING_KEYSTORE_PASSWORD and
# APP_SIGNING_KEY_PASSWORD; the key password defaults to the store password.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() {
  echo "sign_apks: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: scripts/sign_apks.sh --keystore PATH --alias ALIAS [--expected-sha256 HEX] APK...

  --keystore PATH        App signing keystore (PKCS12)
  --alias ALIAS          Key alias in the keystore
  --expected-sha256 HEX  Expected certificate fingerprint; defaults to the
                         keystore certificate
  -h, --help             Show this help

Passwords:
  APP_SIGNING_KEYSTORE_PASSWORD  required
  APP_SIGNING_KEY_PASSWORD       defaults to the store password
EOF
}

keystore=""
alias=""
expected_sha=""
apks=()

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --expected-sha256)
      [[ $# -ge 2 ]] || { usage; die "--expected-sha256 requires a value"; }
      expected_sha="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      usage
      die "unknown option: $1"
      ;;
    *)
      apks+=("$1")
      shift
      ;;
  esac
done

[[ -n "$keystore" ]] || { usage; die "--keystore is required"; }
[[ -n "$alias" ]] || { usage; die "--alias is required"; }
[[ -f "$keystore" ]] || die "keystore not found: $keystore"
((${#apks[@]} > 0)) || { usage; die "at least one APK is required"; }
for apk in "${apks[@]}"; do
  [[ -f "$apk" ]] || die "APK not found: $apk"
done

[[ -n "${APP_SIGNING_KEYSTORE_PASSWORD:-}" ]] ||
  die "APP_SIGNING_KEYSTORE_PASSWORD is not set"
APP_SIGNING_KEY_PASSWORD="${APP_SIGNING_KEY_PASSWORD:-$APP_SIGNING_KEYSTORE_PASSWORD}"
export APP_SIGNING_KEYSTORE_PASSWORD APP_SIGNING_KEY_PASSWORD

sdk_root() {
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -z "$sdk" && -f "$repo_root/app/android/local.properties" ]]; then
    sdk="$(sed -n 's/^sdk\.dir=//p' "$repo_root/app/android/local.properties" | head -n1)"
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

apksigner="$(find_sdk_tool apksigner)" ||
  die "apksigner not found; install the Android SDK build-tools"
zipalign="$(find_sdk_tool zipalign)" ||
  die "zipalign not found; install the Android SDK build-tools"
command -v keytool >/dev/null 2>&1 || die "keytool not found; install a JDK"

normalize_sha() {
  local value="${1//:/}"
  printf '%s' "${value,,}"
}

if [[ -z "$expected_sha" ]]; then
  expected_sha="$(
    keytool -list -v -keystore "$keystore" -alias "$alias" \
      -storepass:env APP_SIGNING_KEYSTORE_PASSWORD 2>/dev/null |
      awk -F': ' '/SHA256:/ { gsub(/:/, "", $2); print tolower($2); exit }'
  )"
  [[ -n "$expected_sha" ]] ||
    die "could not read alias '$alias' from $keystore (wrong password or alias?)"
fi
expected_sha="$(normalize_sha "$expected_sha")"

for apk in "${apks[@]}"; do
  tmp="$(mktemp "$(dirname "$apk")/.sign-apk.XXXXXX")"
  if ! "$apksigner" sign \
    --v4-signing-enabled false \
    --ks "$keystore" \
    --ks-key-alias "$alias" \
    --ks-pass env:APP_SIGNING_KEYSTORE_PASSWORD \
    --key-pass env:APP_SIGNING_KEY_PASSWORD \
    --out "$tmp" "$apk"; then
    rm -f "$tmp"
    die "signing $apk failed; check the app signing key password"
  fi

  signed_cert="$(
    "$apksigner" verify --print-certs "$tmp" |
      sed -n 's/.*certificate SHA-256 digest: //p' | head -n1 | tr 'A-F' 'a-f'
  )"
  if [[ "$signed_cert" != "$expected_sha" ]]; then
    rm -f "$tmp"
    die "$apk signed with $signed_cert, expected $expected_sha"
  fi
  if ! "$zipalign" -c -P 16 4 "$tmp" >/dev/null; then
    rm -f "$tmp"
    die "$apk is not zip-aligned"
  fi
  mv "$tmp" "$apk"
  chmod 644 "$apk"
  echo "signed $apk" >&2
done

echo "app signing certificate SHA-256=$expected_sha" >&2

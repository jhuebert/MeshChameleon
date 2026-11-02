#!/usr/bin/env bash
# Reserve the next repository BUILD_NUMBER for a release or test build.
#
# BUILD_NUMBER is the shared monotonic Android version code counter. The
# calling workflow must serialise reservations with a `build-number`
# concurrency group and pass a token with Actions-variable write permission in
# GH_TOKEN (the default GITHUB_TOKEN cannot manage repository variables).
#
# The variable must already exist and be at least as high as any version code
# already installed or uploaded. This script never resets it.
set -euo pipefail

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
variable="${BUILD_NUMBER_VARIABLE:-BUILD_NUMBER}"
[[ -n "${GH_TOKEN:-}" ]] ||
  { echo "reserve_build_number: GH_TOKEN is not set; configure the REPO_AUTOMATION_TOKEN secret" >&2; exit 1; }

die() {
  echo "reserve_build_number: $*" >&2
  exit 1
}

current="$(
  gh api "repos/$repo/actions/variables/$variable" --jq '.value' 2>/dev/null ||
    true
)"
[[ -n "$current" ]] ||
  die "$variable is not configured; create it above the latest installed version code"
[[ "$current" =~ ^[0-9]+$ ]] ||
  die "$variable has invalid value '$current'"

next=$((current + 1))
gh api --method PATCH "repos/$repo/actions/variables/$variable" \
  --input - >/dev/null <<EOF
{"name":"$variable","value":"$next"}
EOF

echo "build_number=$next" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
echo "Reserved $variable=$next" >&2

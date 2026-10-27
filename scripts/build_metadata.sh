#!/usr/bin/env bash
# Shared build-metadata injection for scripts/build.sh and scripts/run.sh.
#
# Sourced by the wrapper scripts. Sets `metadata_args` for Flutter's
# --dart-define flags. Environment overrides keep CI and reproducible builds
# deterministic:
#   MESHCHAMELEON_GIT_COMMIT, MESHCHAMELEON_GIT_DIRTY, MESHCHAMELEON_BUILD_TIME
# SOURCE_DATE_EPOCH is honoured for the build timestamp when set.
set -euo pipefail

_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

commit="${MESHCHAMELEON_GIT_COMMIT:-}"
if [[ -z "$commit" ]] &&
  git -C "$_repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  commit="$(git -C "$_repo_root" rev-parse --short=12 HEAD)"
fi

dirty="${MESHCHAMELEON_GIT_DIRTY:-}"
if [[ -z "$dirty" ]]; then
  if [[ -n "$(git -C "$_repo_root" status --porcelain 2>/dev/null)" ]]; then
    dirty="1"
  else
    dirty="0"
  fi
fi

build_time="${MESHCHAMELEON_BUILD_TIME:-}"
if [[ -z "$build_time" ]]; then
  if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
    build_time="$(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"
  else
    build_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
fi

metadata_args=(
  "--dart-define=MESHCHAMELEON_GIT_COMMIT=${commit}"
  "--dart-define=MESHCHAMELEON_GIT_DIRTY=${dirty}"
  "--dart-define=MESHCHAMELEON_BUILD_TIME=${build_time}"
)

printf 'Build metadata: commit=%s dirty=%s built=%s\n' \
  "${commit:-unknown}" "$dirty" "$build_time" >&2

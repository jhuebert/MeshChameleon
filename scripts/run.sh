#!/usr/bin/env bash
# Run with Git/build metadata injected into BuildInfo.
# Usage: scripts/run.sh -d linux
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/build_metadata.sh
cd app

FLUTTER="${FLUTTER:-flutter}"
exec "$FLUTTER" run "$@" "${metadata_args[@]}"

#!/usr/bin/env bash
# Build with Git/build metadata injected into BuildInfo.
# Usage: scripts/build.sh apk --release
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/build_metadata.sh
cd app

FLUTTER="${FLUTTER:-flutter}"
exec "$FLUTTER" build "$@" "${metadata_args[@]}"

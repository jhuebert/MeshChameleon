#!/usr/bin/env bash
# Run analysis and tests for every package and the Flutter app.
set -euo pipefail

cd "$(dirname "$0")/.."

DART="${DART:-dart}"
FLUTTER="${FLUTTER:-flutter}"

for pkg in mesh_protocol companion_server device_link mesh_node; do
  echo "== packages/$pkg =="
  (cd "packages/$pkg" && "$DART" pub get >/dev/null && "$DART" analyze && "$DART" test)
done

echo "== app =="
(cd app && "$FLUTTER" pub get >/dev/null && "$FLUTTER" analyze && "$FLUTTER" test)

echo "All checks passed."

#!/usr/bin/env bash
# Run analysis and tests for every package and the Flutter app.
set -euo pipefail

cd "$(dirname "$0")/.."

DART="${DART:-dart}"
FLUTTER="${FLUTTER:-flutter}"

echo "== pub get =="
for pkg in mesh_protocol companion_server device_link mesh_node test_support; do
  (cd "packages/$pkg" && "$DART" pub get >/dev/null)
done
(cd app && "$FLUTTER" pub get >/dev/null)

echo "== format =="
"$DART" format --output=none --set-exit-if-changed \
  packages app/lib app/test app/integration_test tool

for pkg in mesh_protocol companion_server device_link mesh_node test_support; do
  echo "== packages/$pkg =="
  (cd "packages/$pkg" && "$DART" analyze && "$DART" test)
done

echo "== app =="
(cd app && "$FLUTTER" analyze && "$FLUTTER" test)

echo "All checks passed."

#!/usr/bin/env bash
# Run analysis and tests for every package and the Flutter app.
#
# --no-tests runs the format and analysis gates only. CI pairs it with
# scripts/coverage.sh, which runs the same tests once with instrumentation.
set -euo pipefail

cd "$(dirname "$0")/.."

DART="${DART:-dart}"
FLUTTER="${FLUTTER:-flutter}"

run_tests=1
case "${1:-}" in
  "") ;;
  --no-tests) run_tests=0 ;;
  *)
    echo "usage: $0 [--no-tests]" >&2
    exit 64
    ;;
esac

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
  (
    cd "packages/$pkg"
    "$DART" analyze
    if [[ "$run_tests" == 1 ]]; then
      "$DART" test
    fi
  )
done

echo "== app =="
(
  cd app
  "$FLUTTER" analyze
  if [[ "$run_tests" == 1 ]]; then
    "$FLUTTER" test
  fi
)

if [[ "$run_tests" == 1 ]]; then
  echo "All checks passed."
else
  echo "Analysis passed (tests skipped)."
fi

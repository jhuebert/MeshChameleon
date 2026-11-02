#!/usr/bin/env bash
# Run every package/app test with coverage instrumentation and compare the
# per-file line coverage against coverage_baseline.json.
set -euo pipefail

cd "$(dirname "$0")/.."

DART="${DART:-dart}"
FLUTTER="${FLUTTER:-flutter}"
BASELINE="${BASELINE:-coverage_baseline.json}"

write_args=()
if [[ "${1:-}" == "--write-baseline" ]]; then
  write_args=(--write)
fi

rm -rf coverage app/coverage

for pkg in mesh_protocol companion_server device_link mesh_node; do
  echo "== coverage packages/$pkg =="
  (
    cd "packages/$pkg"
    "$DART" pub get >/dev/null
    "$DART" test --coverage="../../coverage/$pkg"
  )
done

echo "== coverage app =="
(
  cd app
  "$FLUTTER" pub get >/dev/null
  "$FLUTTER" test --coverage
)

"$DART" tool/coverage.dart \
  --baseline "$BASELINE" \
  "${write_args[@]}" \
  coverage \
  app/coverage/lcov.info

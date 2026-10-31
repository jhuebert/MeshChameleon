#!/usr/bin/env bash
# Bump the app/product version and promote the changelog's Unreleased section.
#
# Usage: scripts/bump_version.sh <major.minor.patch> <build-number> [notes-file]
#
# Updates:
#   app/pubspec.yaml                              version: X.Y.Z+N
#   packages/mesh_protocol/lib/src/constants.dart  productVersion
#   packages/mesh_protocol/lib/src/models.dart     DeviceInfo.version default
#   docs/USER_GUIDE.md                            version line
#   CHANGELOG.md                                  Unreleased -> X.Y.Z heading
#
# The optional notes file is inserted under the new release heading; existing
# Unreleased entries are preserved below it. The script is intended to run on a
# clean release branch and does not commit anything itself.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

usage() {
  echo "usage: $0 <major.minor.patch> <build-number> [notes-file]" >&2
}

die() {
  echo "bump_version: $*" >&2
  exit 1
}

version="${1:-}"
build_number="${2:-}"
notes_file="${3:-}"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  usage
  die "invalid version '$version'"
}
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || {
  usage
  die "invalid build number '$build_number'"
}
if [[ -n "$notes_file" && ! -f "$notes_file" ]]; then
  die "notes file not found: $notes_file"
fi

pubspec="app/pubspec.yaml"
constants="packages/mesh_protocol/lib/src/constants.dart"
models="packages/mesh_protocol/lib/src/models.dart"
user_guide="docs/USER_GUIDE.md"
changelog="CHANGELOG.md"

for file in "$pubspec" "$constants" "$models" "$user_guide" "$changelog"; do
  [[ -f "$file" ]] || die "missing $file"
done

sed -i -E "s/^version: .*/version: ${version}+${build_number}/" "$pubspec"
sed -i -E \
  "s/^const String productVersion = '[^']*';/const String productVersion = '${version}';/" \
  "$constants"
sed -i -E \
  "s/(this\\.version = 'meshchameleon )[^']*(')/\\1${version}\\2/" \
  "$models"
sed -i -E \
  "1,5s/^Version [0-9]+\\.[0-9]+\\.[0-9]+ · Android$/Version ${version} · Android/" \
  "$user_guide"

today="$(date -u +%Y-%m-%d)"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

awk -v version="$version" -v today="$today" -v notes="$notes_file" '
  /^## \[Unreleased\]$/ && !promoted {
    print "## [Unreleased]"
    print ""
    print "## [" version "] - " today
    print ""
    if (notes != "") {
      while ((getline line < notes) > 0) print line
      close(notes)
    }
    promoted = 1
    next
  }
  { print }
  END { if (!promoted) exit 3 }
' "$changelog" > "$tmp" || die "CHANGELOG.md has no '## [Unreleased]' section"
mv "$tmp" "$changelog"
trap - EXIT

echo "bumped to ${version}+${build_number}"

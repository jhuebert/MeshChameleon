#!/usr/bin/env bash
# Validate Play/store image assets before a release.
#
# Branding assets are always checked. If docs/store/ exists, its Play assets
# are validated too; pass --require-store to fail when that directory is
# missing (use once the store listing assets are committed).
set -euo pipefail

cd "$(dirname "$0")/.."
require_store=0
if [[ "${1:-}" == "--require-store" ]]; then
  require_store=1
fi

python3 - "$require_store" <<'PY'
import struct
import sys
from pathlib import Path

require_store = sys.argv[1] == "1"
errors: list[str] = []


def png_info(path: Path) -> tuple[int, int, int, int]:
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("not a PNG file")
    if len(data) < 26:
        raise ValueError("truncated PNG header")
    width, height = struct.unpack(">II", data[16:24])
    return width, height, data[24], data[25]


def check_png(
    path: Path,
    *,
    size: tuple[int, int] | None = None,
    max_ratio: float | None = None,
) -> None:
    if not path.is_file():
        errors.append(f"missing {path}")
        return
    try:
        width, height, _bit_depth, _color_type = png_info(path)
    except (OSError, ValueError) as exc:
        errors.append(f"{path}: {exc}")
        return
    if size is not None and (width, height) != size:
        errors.append(f"{path}: expected {size[0]}x{size[1]}, got {width}x{height}")
    if max_ratio is not None and max(width, height) > min(width, height) * max_ratio:
        errors.append(f"{path}: aspect ratio exceeds {max_ratio:g}:1 ({width}x{height})")


branding = Path("app/assets/branding")
branding_assets = {
    "icon.png": (1024, 1024),
    "icon_background.png": (1024, 1024),
    "icon_foreground.png": (1024, 1024),
    "icon_monochrome.png": (1024, 1024),
    "splash_logo.png": (1152, 1152),
}
for name, size in branding_assets.items():
    check_png(branding / name, size=size)
check_png(branding / "wordmark.png")

store = Path("docs/store")
if store.is_dir():
    check_png(store / "feature-graphic.png", size=(1024, 500))
    screenshots = sorted((store / "screenshots").glob("*.png"))
    if not 2 <= len(screenshots) <= 8:
        errors.append(
            f"docs/store/screenshots: expected 2-8 PNGs, found {len(screenshots)}"
        )
    for screenshot in screenshots:
        check_png(screenshot, max_ratio=2.0)
elif require_store:
    errors.append("docs/store is missing (run with store assets committed)")
else:
    print("No docs/store assets yet; branding checks passed.")

if errors:
    print("Store asset check failed:", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    sys.exit(1)
print("Store assets OK.")
PY

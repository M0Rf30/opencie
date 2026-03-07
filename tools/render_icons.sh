#!/usr/bin/env bash
# render_icons.sh — Rasterize assets/branding/icon.svg into every platform
# launcher icon (macOS appiconset, Android mipmaps, Linux runner, Windows .ico).
#
# Requires: rsvg-convert (librsvg) and python-pillow.
# Run from repo root: ./tools/render_icons.sh
#
# CI parity: macOS DMG .icns and Inno Setup wizard BMPs are still generated
# inside .github/workflows/main.yml from the same source PNGs (see
# app_icon_1024.png / app_icon.ico) so this script only needs to (re)write
# those source PNGs.

set -euo pipefail

SVG="assets/branding/icon.svg"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -f "$SVG" ]]; then
  echo "error: $SVG not found" >&2
  exit 1
fi

for cmd in rsvg-convert python; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: $cmd not on PATH" >&2
    exit 1
  fi
done

if ! python -c "import PIL" >/dev/null 2>&1; then
  echo "error: Python Pillow not available (pip install Pillow)" >&2
  exit 1
fi

render() {
  # render <size> <out>
  rsvg-convert -w "$1" -h "$1" -o "$2" "$SVG"
}

echo "→ macOS appiconset (16/32/64/128/256/512/1024)"
for s in 16 32 64 128 256 512 1024; do
  render "$s" "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_${s}.png"
done

echo "→ Android mipmaps (mdpi 48 / hdpi 72 / xhdpi 96 / xxhdpi 144 / xxxhdpi 192)"
declare -a ANDROID=(
  "mdpi:48" "hdpi:72" "xhdpi:96" "xxhdpi:144" "xxxhdpi:192"
)
for entry in "${ANDROID[@]}"; do
  d="${entry%:*}"
  s="${entry#*:}"
  render "$s" "android/app/src/main/res/mipmap-${d}/ic_launcher.png"
done

echo "→ Linux runner (512 master + 48 hicolor)"
render 512 "linux/runner/resources/io.github.m0rf30.opencie.png"
render 256 "linux/runner/resources/io.github.m0rf30.opencie_256.png"
render 128 "linux/runner/resources/io.github.m0rf30.opencie_128.png"
render 48  "linux/runner/resources/io.github.m0rf30.opencie_48.png"

echo "→ Windows .ico (multi-frame 16/32/48/64/128/256)"
for s in 16 32 48 64 128 256; do
  render "$s" "$TMP/ico_${s}.png"
done
TMP_DIR="$TMP" python - <<'PY'
# Assemble a proper multi-frame .ico from per-size PNGs.
# We write the canonical ICO container ourselves (tiny binary format) so each
# frame keeps its own crisp render — Pillow's auto-downsampling at small
# sizes is unacceptable for an app launcher icon.
import os, struct

tmp = os.environ["TMP_DIR"]
sizes = [16, 32, 48, 64, 128, 256]

# Read raw PNG bytes for each size
png_bytes = []
for s in sizes:
    with open(f"{tmp}/ico_{s}.png", "rb") as f:
        png_bytes.append(f.read())

# ICONDIR (6 bytes): reserved=0, type=1 (icon), count
header = struct.pack("<HHH", 0, 1, len(sizes))

# ICONDIRENTRY is 16 bytes per entry; offsets follow the directory
dir_size = 6 + 16 * len(sizes)
entries = b""
data = b""
offset = dir_size
for s, blob in zip(sizes, png_bytes):
    width = 0 if s >= 256 else s   # 0 means 256 in ICO spec
    height = 0 if s >= 256 else s
    # width, height, palette=0, reserved=0, planes=1, bpp=32, size, offset
    entries += struct.pack(
        "<BBBBHHII", width, height, 0, 0, 1, 32, len(blob), offset
    )
    data += blob
    offset += len(blob)

with open("windows/runner/resources/app_icon.ico", "wb") as f:
    f.write(header + entries + data)
PY

echo "✓ done"

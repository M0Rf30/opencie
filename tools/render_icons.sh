#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Gianluca Boiano
# SPDX-License-Identifier: GPL-3.0-or-later

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

# Adaptive icon (API 26+). Without it the launcher shrinks the legacy PNG
# into a white plate. The background layer is the full-bleed gradient; the
# foreground is the card + waves on transparency, scaled so the 128 viewBox
# maps to the 72dp inner area of the 108dp canvas (content stays inside the
# 66dp safe zone of every mask shape).
echo "→ Android adaptive icon layers (108dp: 108/162/216/324/432)"
SVG="$SVG" TMP_DIR="$TMP" python - <<'PY'
import os, re
src = open(os.environ["SVG"], encoding="utf-8").read()
tmp = os.environ["TMP_DIR"]
defs = re.search(r"<defs>.*?</defs>", src, re.S).group(0)
body = src.split("</defs>", 1)[1].rsplit("</svg>", 1)[0]
body = re.sub(r'\s*<rect width="128" height="128" rx="28"[^>]*/>', "", body)
head = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108" '
        'width="108" height="108">')
fg = (head + defs + '<g transform="translate(18 18) scale(0.5625)">'
      + body + "</g></svg>")
bg = (head + defs + '<g transform="scale(0.84375)">'
      '<rect width="128" height="128" fill="url(#bg)"/>'
      '<rect width="128" height="128" fill="url(#glow)"/></g></svg>')
open(os.path.join(tmp, "fg.svg"), "w", encoding="utf-8").write(fg)
open(os.path.join(tmp, "bg.svg"), "w", encoding="utf-8").write(bg)
PY
for entry in "mdpi:108" "hdpi:162" "xhdpi:216" "xxhdpi:324" "xxxhdpi:432"; do
  d="${entry%:*}"
  s="${entry#*:}"
  out="android/app/src/main/res/mipmap-${d}"
  rsvg-convert -w "$s" -h "$s" -o "$out/ic_launcher_foreground.png" "$TMP/fg.svg"
  rsvg-convert -w "$s" -h "$s" -o "$out/ic_launcher_background.png" "$TMP/bg.svg"
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

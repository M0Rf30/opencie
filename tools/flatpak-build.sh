#!/usr/bin/env bash
# flatpak-build.sh — Build and install the OpenCIE Flatpak locally for testing.
#
# Stages the host libraries that the Freedesktop 24.08 runtime does not ship
# (cryptopp, pcsclite, libxml2>=2.14 + its ICU), builds the Flutter Linux
# bundle, then assembles the Flatpak from flatpak/io.github.m0rf30.opencie.yml
# and installs it into the user installation.
#
# Run from repo root: ./tools/flatpak-build.sh
# Then: flatpak run io.github.m0rf30.opencie

set -euo pipefail

cd "$(dirname "$0")/.."

FLUTTER=flutter
[ -x .fvm/flutter_sdk/bin/flutter ] && FLUTTER=.fvm/flutter_sdk/bin/flutter

echo "→ flutter build linux --release"
"$FLUTTER" build linux --release

echo "→ staging runtime-missing libs into flatpak/deps-libs/"
mkdir -p flatpak/deps-libs
rm -f flatpak/deps-libs/*
# libjpeg.so.8: runtime ships libjpeg.so.62 only (Freedesktop 24.08)
# libpcsclite_real.so.1: Arch's libpcsclite.so.1 is a wrapper that dlopens it
for lib in libcryptopp.so.8 libpcsclite.so.1 libpcsclite_real.so.1 libxml2.so.16 libjpeg.so.8; do
  cp -L "/usr/lib/$lib" flatpak/deps-libs/
done
# libxml2 >= 2.14 pulls in the host's ICU
for icu in /usr/lib/libicuuc.so.* /usr/lib/libicudata.so.*; do
  case "$icu" in *.so.[0-9][0-9]) cp -L "$icu" flatpak/deps-libs/ ;; esac
done

echo "→ flatpak-builder"
flatpak-builder --user --install --force-clean \
  --state-dir=.flatpak-builder \
  flatpak/build flatpak/io.github.m0rf30.opencie.yml

echo "✓ installed — run with: flatpak run io.github.m0rf30.opencie"

#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Gianluca Boiano
# SPDX-License-Identifier: GPL-3.0-or-later

# sync-jnilibs.sh — Download pre-built libopencie-pkcs11.so for all Android
# ABIs from the latest opencie-pkcs11 GitHub release into jniLibs/.
#
# Usage:
#   ./scripts/sync-jnilibs.sh [TAG]
#
# If TAG is omitted, the latest release tag is used.
# Downloads are checksum-verified against the release's SHA256SUMS via
# fetch-pkcs11.sh before being installed.
# Requires: gh (GitHub CLI) or curl + jq.
#
# ABI mapping:
#   arm64-v8a   ← libopencie-pkcs11-<TAG>-android-arm64.so
#   armeabi-v7a ← libopencie-pkcs11-<TAG>-android-armv7.so
#   x86_64      ← libopencie-pkcs11-<TAG>-android-x86_64.so

set -euo pipefail

REPO="M0Rf30/opencie-pkcs11"
JNILIBS_DIR="$(dirname "$0")/../android/app/src/main/jniLibs"

if [[ $# -ge 1 ]]; then
	TAG="$1"
else
	TAG=$(gh api "repos/$REPO/releases/latest" --jq '.tag_name')
fi

echo "Syncing libopencie-pkcs11 Android libraries from $REPO @ $TAG"

# "<abi>:<asset suffix>" pairs (no associative arrays: bash 3.2 compatible).
ABI_PAIRS="arm64-v8a:android-arm64 armeabi-v7a:android-armv7 x86_64:android-x86_64"

# Some ABIs may not be published in every release (e.g. armeabi-v7a was dropped
# in 1.0.0). Skip cleanly when the asset is missing rather than failing CI.
ASSETS=$(gh api "repos/$REPO/releases/tags/$TAG" --jq '.assets[].name')

for PAIR in $ABI_PAIRS; do
	ABI="${PAIR%%:*}"
	ASSET_SUFFIX="${PAIR#*:}"
	ASSET_NAME="libopencie-pkcs11-${TAG}-${ASSET_SUFFIX}.so"
	DEST_DIR="$JNILIBS_DIR/$ABI"
	DEST_FILE="$DEST_DIR/libopencie-pkcs11.so"

	if ! grep -qx "$ASSET_NAME" <<<"$ASSETS"; then
		echo "  [$ABI] $ASSET_NAME not in release — skipping."
		# Drop any stale jniLib so the APK doesn't ship an outdated binary.
		rm -f "$DEST_FILE"
		continue
	fi

	echo "  [$ABI] Downloading $ASSET_NAME ..."
	"$(dirname "$0")/fetch-pkcs11.sh" "$TAG" "$ASSET_NAME" "$DEST_FILE"
	echo "  [$ABI] → $DEST_FILE"
done

echo "Done. jniLibs updated to $TAG."

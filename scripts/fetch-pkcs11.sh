#!/usr/bin/env bash
# fetch-pkcs11.sh — Download one asset from an opencie-pkcs11 release and
# verify it against the release's SHA256SUMS before it is used by a build.
#
# Usage:
#   ./scripts/fetch-pkcs11.sh TAG PATTERN OUT_FILE
#
# PATTERN must match exactly one asset (globs are passed to `gh release
# download --pattern`). The asset is rejected unless SHA256SUMS lists it and
# the digest matches, so a tampered or truncated download can never reach a
# build. Verified bytes are moved to OUT_FILE.
#
# Requires: gh (GitHub CLI), sha256sum or shasum (macOS runners lack the former).

set -euo pipefail

REPO="M0Rf30/opencie-pkcs11"

if [[ $# -ne 3 ]]; then
	echo "usage: $0 TAG PATTERN OUT_FILE" >&2
	exit 2
fi

TAG="$1"
PATTERN="$2"
OUT_FILE="$3"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

gh release download "$TAG" \
	--repo "$REPO" \
	--pattern "$PATTERN" \
	--pattern SHA256SUMS \
	--dir "$TMP_DIR"

if [[ ! -f "$TMP_DIR/SHA256SUMS" ]]; then
	echo "::error::$REPO release $TAG publishes no SHA256SUMS — refusing to use unverified $PATTERN" >&2
	exit 1
fi

# macOS runners default to bash 3.2 — no mapfile/associative arrays.
ASSET=""
MATCHED=0
for path in "$TMP_DIR"/*; do
	name="$(basename "$path")"
	[[ "$name" == SHA256SUMS ]] && continue
	ASSET="$name"
	MATCHED=$((MATCHED + 1))
done

if [[ $MATCHED -eq 0 ]]; then
	echo "::error::no asset matching '$PATTERN' in $REPO release $TAG" >&2
	exit 1
fi
if [[ $MATCHED -gt 1 ]]; then
	echo "::error::'$PATTERN' matched $MATCHED assets in $REPO release $TAG" >&2
	exit 1
fi

EXPECTED="$(awk -v name="$ASSET" '$2 == name || $2 == "*" name { print tolower($1) }' "$TMP_DIR/SHA256SUMS")"
if [[ -z "$EXPECTED" ]]; then
	echo "::error::$ASSET is not listed in SHA256SUMS of $REPO release $TAG" >&2
	exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
	ACTUAL="$(sha256sum "$TMP_DIR/$ASSET")"
else
	ACTUAL="$(shasum -a 256 "$TMP_DIR/$ASSET")"
fi
ACTUAL="$(tr 'A-Z' 'a-z' <<<"${ACTUAL%% *}")"

if [[ "$ACTUAL" != "$EXPECTED" ]]; then
	echo "::error::checksum mismatch for $ASSET: expected $EXPECTED, got $ACTUAL" >&2
	exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"
mv -f "$TMP_DIR/$ASSET" "$OUT_FILE"
echo "$ASSET verified (sha256 $EXPECTED) → $OUT_FILE"

#!/usr/bin/env bash
set -Eeuo pipefail

REPO="@@REPO@@"
TAG="@@TAG@@"
SOURCE_NAME="@@SOURCE_NAME@@"
SOURCE_SHA256="@@SOURCE_SHA256@@"
SOURCE_COMMIT="@@SOURCE_COMMIT@@"
BASE="https://github.com/$REPO/releases/download/$TAG"
TMP="$(mktemp -d /tmp/cape-inetsim-release.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

command -v curl >/dev/null 2>&1 || { echo "[FAIL] curl is required" >&2; exit 2; }
command -v tar >/dev/null 2>&1 || { echo "[FAIL] tar is required" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo "[FAIL] sha256sum is required" >&2; exit 2; }

echo "[INFO] CAPE-INetSim-AutoDeploy $TAG"
echo "[INFO] Fetching checksum-pinned runtime source"

curl --fail --location --proto '=https' --tlsv1.2 --retry 5 --retry-all-errors \
  --continue-at - --output "$TMP/$SOURCE_NAME.part" "$BASE/$SOURCE_NAME"

ACTUAL="$(sha256sum "$TMP/$SOURCE_NAME.part" | awk '{print $1}')"
[[ "$ACTUAL" == "$SOURCE_SHA256" ]] || {
  echo "[FAIL] runtime source SHA-256 mismatch" >&2
  echo "expected=$SOURCE_SHA256" >&2
  echo "actual=$ACTUAL" >&2
  exit 3
}
mv "$TMP/$SOURCE_NAME.part" "$TMP/$SOURCE_NAME"

tar -xzf "$TMP/$SOURCE_NAME" -C "$TMP"
ROOT="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -name 'CAPE-INetSim-AutoDeploy-*' | head -1)"
[[ -n "$ROOT" && -f "$ROOT/install" ]] || { echo "[FAIL] runtime bundle layout is invalid" >&2; exit 4; }

printf '%s\n' "$SOURCE_COMMIT" >"$TMP/SOURCE-COMMIT"
chmod +x "$ROOT/install" "$ROOT"/bin/cape-inetsim-* 2>/dev/null || true
export CAPE_INETSIM_BOOTSTRAPPED=1
exec "$ROOT/install" "$@"

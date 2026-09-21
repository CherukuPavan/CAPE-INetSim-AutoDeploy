#!/usr/bin/env bash
set -Eeuo pipefail

REPO="CherukuPavan/CAPE-INetSim-AutoDeploy"
TAG="@@TAG@@"
SOURCE_NAME="@@SOURCE_NAME@@"
SOURCE_SHA256="@@SOURCE_SHA256@@"
SOURCE_URL="https://github.com/$REPO/releases/download/$TAG/$SOURCE_NAME"

command -v curl >/dev/null 2>&1 || { echo "[FAIL] curl is required" >&2; exit 2; }
command -v tar >/dev/null 2>&1 || { echo "[FAIL] tar is required" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo "[FAIL] sha256sum is required" >&2; exit 2; }

TMP="$(mktemp -d /tmp/cape-inetsim-autodeploy-release.XXXXXX)"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  "$SOURCE_URL" -o "$TMP/$SOURCE_NAME"
printf '%s  %s\n' "$SOURCE_SHA256" "$TMP/$SOURCE_NAME" | sha256sum -c - >/dev/null

tar -xzf "$TMP/$SOURCE_NAME" -C "$TMP"
ROOT="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -name 'CAPE-INetSim-AutoDeploy-*' | head -1)"
[[ -n "$ROOT" && -f "$ROOT/install" && -f "$ROOT/lib/common.sh" ]] || {
  echo "[FAIL] Release source bundle layout is invalid" >&2
  exit 2
}

chmod +x "$ROOT/install" "$ROOT"/bin/* "$ROOT"/tests/*.sh 2>/dev/null || true
trap - EXIT
exec "$ROOT/install" "$@"

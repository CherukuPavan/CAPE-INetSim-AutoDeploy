#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/appliance.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf 'fake qcow2 bytes for checksum test\n' >"$TMP/a.qcow2"
sha="$(sha256sum "$TMP/a.qcow2" | awk '{print $1}')"
cat >"$TMP/manifest.json" <<EOF2
{
  "schema":1,
  "appliance_version":"test",
  "status":"published",
  "artifact_name":"a.qcow2",
  "artifact_url":"https://example.invalid/a.qcow2",
  "sha256":"$sha",
  "format":"qcow2",
  "os":{},
  "inetsim":{}
}
EOF2
appliance_manifest_validate "$TMP/manifest.json" >/dev/null
have(){ return 1; }
appliance_verify_file "$TMP/a.qcow2" "$TMP/manifest.json" >/dev/null

if appliance_manifest_validate "$ROOT/appliance/manifest.json" >/dev/null 2>&1; then
  echo 'repository manifest unexpectedly marked published' >&2
  exit 1
else
  rc=$?
  [[ "$rc" -eq 3 ]]
fi

echo '[PASS] appliance manifest/checksum gates'

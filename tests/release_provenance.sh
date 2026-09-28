#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/release-provenance.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/release"
cat >"$TMP/release/source-provenance.json" <<'EOF'
{
  "schema": 1,
  "release_tag": "v1.0.0-rc.70",
  "source_commit": "0123456789abcdef0123456789abcdef01234567",
  "candidate_run_id": 1,
  "source_bundle": "CAPE-INetSim-AutoDeploy-1.0.0-rc.70.tar.gz"
}
EOF
printf "test bundle\n" >"$TMP/CAPE-INetSim-AutoDeploy-1.0.0-rc.70.tar.gz"
unset CAPE_INETSIM_RELEASE_TAG CAPE_INETSIM_RELEASE_SOURCE_COMMIT CAPE_INETSIM_RELEASE_SOURCE_BUNDLE CAPE_INETSIM_RELEASE_SOURCE_SHA256 || true
cape_autodiscover_release_provenance "$TMP"
[[ "$CAPE_INETSIM_RELEASE_TAG" == v1.0.0-rc.70 ]]
[[ "$CAPE_INETSIM_RELEASE_SOURCE_COMMIT" == 0123456789abcdef0123456789abcdef01234567 ]]
[[ "$CAPE_INETSIM_RELEASE_SOURCE_BUNDLE" == CAPE-INetSim-AutoDeploy-1.0.0-rc.70.tar.gz ]]
EXPECTED="$(sha256sum "$TMP/CAPE-INetSim-AutoDeploy-1.0.0-rc.70.tar.gz" | awk '{print $1}')"
[[ "$CAPE_INETSIM_RELEASE_SOURCE_SHA256" == "$EXPECTED" ]]
echo "[PASS] direct repair auto-discovers release tag/source commit/bundle SHA"

# Explicit caller-supplied provenance always wins over the embedded metadata.
export CAPE_INETSIM_RELEASE_TAG=v1.0.0-rc.69
export CAPE_INETSIM_RELEASE_SOURCE_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export CAPE_INETSIM_RELEASE_SOURCE_BUNDLE=CAPE-INetSim-AutoDeploy-1.0.0-rc.69.tar.gz
unset CAPE_INETSIM_RELEASE_SOURCE_SHA256 || true
cape_autodiscover_release_provenance "$TMP"
[[ "$CAPE_INETSIM_RELEASE_TAG" == v1.0.0-rc.69 ]]
[[ "$CAPE_INETSIM_RELEASE_SOURCE_COMMIT" == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]]
[[ "$CAPE_INETSIM_RELEASE_SOURCE_BUNDLE" == CAPE-INetSim-AutoDeploy-1.0.0-rc.69.tar.gz ]]
echo "[PASS] explicit repair provenance remains authoritative"

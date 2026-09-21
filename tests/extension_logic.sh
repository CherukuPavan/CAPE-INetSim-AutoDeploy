#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
AD_STATE_ROOT=/tmp/unused
APPLIANCE_CACHE_ROOT=/tmp/unused-cache
source "$ROOT/lib/extension.sh"
[[ "$EXTENSION_VERSION" == 1.0.1 ]]
[[ "$EXTENSION_RELEASE_ASSET_SHA256" == f3be934f08ad364d5964842d3db9bfea0f11cd40a44b76980855d692d3a34d87 ]]
[[ "$EXTENSION_BUNDLED_ROOT" == "$ROOT/vendor/CAPE-INetSim-VM-Extension-v1.0.1" ]]
(cd "$EXTENSION_BUNDLED_ROOT" && sha256sum -c RUNTIME-SHA256SUMS >/dev/null)
grep -Fq 'Bundled INetSim extension runtime' "$ROOT/lib/extension.sh"
! grep -Fq 'CAPE-INetSim-VM-Extension/releases/download' "$ROOT/lib/extension.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
EXTENSION_ROOT="$TMP/ext"
mkdir -p "$EXTENSION_ROOT/src"
CAPE_ROOT='/opt/CAPE test/$root'
CAPE_MACHINE_SECTION='win test'
CAPE_MACHINE_IP='192.0.2.100'
CAPE_RESULTSERVER_IP='192.0.2.1'
INETSIM_IP='198.51.100.2'
WINDOWS_FAKE_IP='198.51.100.10'
ISOLATED_BRIDGE_NAME='capeisim7'
extension_write_config
unset CAPE_ROOT CAPE_MACHINE CAPE_GUEST_CONTROL_IP CAPE_RESULTSERVER_IP INETSIM_SERVER_IP ANALYSIS_GUEST_IP CAPTURE_INTERFACE
# shellcheck disable=SC1090
source "$EXTENSION_ROOT/src/inetsim-vm.conf"
[[ "$CAPE_ROOT" == '/opt/CAPE test/$root' ]]
[[ "$CAPE_MACHINE" == 'win test' ]]
[[ "$CAPE_GUEST_CONTROL_IP" == '192.0.2.100' ]]
[[ "$CAPE_RESULTSERVER_IP" == '192.0.2.1' ]]
[[ "$INETSIM_SERVER_IP" == '198.51.100.2' ]]
[[ "$ANALYSIS_GUEST_IP" == '198.51.100.10' ]]
[[ "$CAPTURE_INTERFACE" == 'capeisim7' ]]

echo '[PASS] vendored extension runtime is version/checksum pinned and credential-free'

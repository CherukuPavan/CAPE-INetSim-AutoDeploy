#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
AD_STATE_ROOT=/tmp/unused
APPLIANCE_CACHE_ROOT=/tmp/unused-cache
source "$ROOT/lib/extension.sh"
[[ "$EXTENSION_VERSION" == 1.0.1 ]]
[[ "$EXTENSION_SHA256" == f3be934f08ad364d5964842d3db9bfea0f11cd40a44b76980855d692d3a34d87 ]]
[[ "$EXTENSION_URL" == https://github.com/CherukuPavan/CAPE-INetSim-VM-Extension/releases/download/v1.0.1/CAPE-INetSim-VM-Extension-v1.0.1.tar.gz ]]
echo '[PASS] frozen extension version/checksum constants'

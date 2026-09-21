#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/windows-control.sh"
CAPE_MACHINE_IP=192.168.122.100
WINDOWS_ISOLATED_MAC=52:54:00:aa:bb:cc
WINDOWS_FAKE_IP=192.168.200.10
INETSIM_IP=192.168.200.2
CAPE_RESULTSERVER_IP=192.168.122.1
CAPE_RESULTSERVER_PORT=2042
CONTROL_HOST_IP=192.168.122.1
cmd="$(windows_manual_command)"
[[ "$cmd" == powershell.exe*EncodedCommand* ]]
[[ "$(wc -w <<<"$cmd")" -eq 6 ]]
echo '[PASS] Windows backend controller and one-command fallback generation'

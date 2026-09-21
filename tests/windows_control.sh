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
cmd="$(windows_manual_callback_command 'http://192.168.122.1:54321' 'test-token')"
[[ "$cmd" == powershell.exe* ]]
grep -Fq 'http://192.168.122.1:54321' <<<"$cmd"
grep -Fq 'test-token' <<<"$cmd"
grep -Fq -- "-IsolatedMac '52:54:00:aa:bb:cc'" <<<"$cmd"
grep -Fq "Invoke-WebRequest" <<<"$cmd"
python3 -m py_compile "$ROOT/tools/windows_callback.py"
echo '[PASS] Windows backend controller and one-command callback fallback generation'

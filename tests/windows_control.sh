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
grep -Fq -- '--client "$CAPE_MACHINE_IP"' "$ROOT/lib/windows-control.sh"
grep -Fq 'self.client_address[0]' "$ROOT/tools/windows_callback.py"
grep -Fq 'peer != allowed_client' "$ROOT/tools/windows_callback.py"
grep -Fq 'paused) virsh resume "$DOMAIN"' "$ROOT/lib/windows-control.sh"
grep -Fq 'windows_wait_for_cape_agent_visible' "$ROOT/lib/windows-control.sh"
grep -Fq 'Still waiting for CAPE Agent' "$ROOT/lib/windows-control.sh"

# Long control probes must show progress rather than looking frozen.
CAPE_AGENT_PORT=8000
cape_agent_wait(){ return 1; }
wait_log="$(windows_wait_for_cape_agent_visible 192.0.2.50 16 2>&1 || true)"
grep -Fq 'Waiting up to 16s for CAPE Agent on 192.0.2.50:8000' <<<"$wait_log"
grep -Fq 'Still waiting for CAPE Agent on 192.0.2.50:8000 (15s/16s)' <<<"$wait_log"
echo '[PASS] Windows backend controller and one-command callback fallback generation'

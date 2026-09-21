#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"

python3 -m py_compile "$ROOT/tools/winrm_exec.py"
grep -q 'windows_winrm_ready' "$ROOT/lib/windows-winrm.sh"
grep -q 'configured-via-winrm' "$ROOT/lib/windows-winrm.sh"
grep -q 'CAPE_INETSIM_WINRM_PASSWORD_FILE' "$ROOT/lib/windows-winrm.sh"
grep -q 'CAPE_INETSIM_WINRM_CERT_VALIDATION' "$ROOT/lib/windows-winrm.sh"

python3 - "$ROOT/lib/windows-control.sh" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()
q=s.index('if qga_wait "$DOMAIN" 10; then')
w=s.index('if windows_winrm_ready "$CAPE_MACHINE_IP"')
m=s.index('WINDOWS_BACKEND_USED=manual-powershell', w)
assert q < w < m
assert "cape_agent_probe" not in s
assert "WINDOWS_BACKEND_USED=cape-agent" not in s
PY

! grep -q 'windows-cape-agent.sh' "$ROOT/install"
[[ ! -e "$ROOT/lib/windows-cape-agent.sh" ]]

grep -q 'Get-NetAdapter' "$ROOT/windows/configure-inetsim.ps1"
grep -q "DestinationPrefix '0.0.0.0/0'" "$ROOT/windows/configure-inetsim.ps1"
grep -q "DestinationPrefix '::/0'" "$ROOT/windows/configure-inetsim.ps1"
grep -q 'Disable-NetAdapterBinding' "$ROOT/windows/configure-inetsim.ps1"
grep -q 'unexpected active network adapter' "$ROOT/windows/configure-inetsim.ps1"
grep -q '2606:4700:4700::1111' "$ROOT/windows/configure-inetsim.ps1"
grep -q 'Test-NetConnection' "$ROOT/windows/configure-inetsim.ps1"
grep -q 'Resolve-DnsName' "$ROOT/windows/configure-inetsim.ps1"
grep -q 'public_ipv6_reachable' "$ROOT/windows/verify-inetsim.ps1"

echo '[PASS] QGA -> approved WinRM -> one-command fallback and Windows safety gates'

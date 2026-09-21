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
grep -q 'inetsim_https_reachable' "$ROOT/windows/configure-inetsim.ps1"
grep -q 'inetsim_https_reachable' "$ROOT/windows/verify-inetsim.ps1"
grep -Fq 'validate_windows_result_path "$local_result"' "$ROOT/lib/windows-qga.sh"
[[ "$(grep -Fc 'validate_windows_result_path "$local_result"' "$ROOT/lib/windows-winrm.sh")" -eq 2 ]]

source "$ROOT/lib/common.sh"
source "$ROOT/lib/validate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WINDOWS_FAKE_IP=192.0.2.10
INETSIM_IP=192.0.2.2
cat >"$TMP/result.json" <<'EOF'
{
  "ok": true,
  "default_routes": 0,
  "ipv4_default_routes": 0,
  "ipv6_default_routes": 0,
  "ipv6_bindings_enabled": 0,
  "unexpected_active_adapters": 0,
  "resultserver_reachable": true,
  "inetsim_http_reachable": true,
  "inetsim_https_reachable": true,
  "public_ip_reachable": false,
  "public_ipv6_reachable": false,
  "fake_ip": "192.0.2.10",
  "dns": "192.0.2.2"
}
EOF
validate_windows_result_path "$TMP/result.json"
python3 - "$TMP/result.json" <<'PY'
import json,sys
p=sys.argv[1]
d=json.load(open(p))
d["inetsim_https_reachable"]=False
json.dump(d,open(p,"w"))
PY
if validate_windows_result_path "$TMP/result.json" >/dev/null 2>&1; then
  echo 'Windows validator accepted missing HTTPS safety gate' >&2
  exit 1
fi

echo '[PASS] QGA -> approved WinRM -> one-command fallback and Windows safety gates'

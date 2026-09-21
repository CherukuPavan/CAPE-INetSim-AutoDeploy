#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"

python3 -m py_compile "$ROOT/tools/winrm_exec.py" "$ROOT/tools/windows_agent_runner.py"
grep -q 'windows_winrm_ready' "$ROOT/lib/windows-winrm.sh"
grep -q 'configured-via-winrm' "$ROOT/lib/windows-winrm.sh"
grep -q 'CAPE_INETSIM_WINRM_PASSWORD_FILE' "$ROOT/lib/windows-winrm.sh"
grep -q 'CAPE_INETSIM_WINRM_CERT_VALIDATION' "$ROOT/lib/windows-winrm.sh"

source "$ROOT/lib/windows-winrm.sh"
probe_tcp(){ return 0; }
[[ "$(windows_winrm_port 192.0.2.1)" == 5986 ]]

python3 - "$ROOT/lib/windows-control.sh" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()
q=s.index('if qga_wait "$DOMAIN" 10; then')
w=s.index('if windows_winrm_ready "$CAPE_MACHINE_IP"')
a=s.index('if cape_agent_wait "$CAPE_MACHINE_IP" 45', w)
z=s.index('No supported zero-touch Windows control channel is available', a)
assert q < w < a < z
assert "WINDOWS_BACKEND_USED=cape-agent-execpy" in s
assert "WINDOWS_BACKEND_USED=manual-powershell" not in s[s.index("windows_select_live_backend()"):s.index("windows_configure_selected_backend()")]
PY

grep -q 'windows-cape-agent.sh' "$ROOT/install"
[[ -e "$ROOT/lib/windows-cape-agent.sh" ]]
grep -Fq '/execpy' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq '/store' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq '/retrieve' "$ROOT/lib/windows-cape-agent.sh"
! grep -Fq '/execute' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'rc=50' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'cape_agent_remove "$ip" "$remote_runner"' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq '{"execpy","largefile"}' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'd.get("is_user_admin") is not True' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'subprocess.run(cmd' "$ROOT/tools/windows_agent_runner.py"
! grep -Fq 'shell=True' "$ROOT/tools/windows_agent_runner.py"

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
[[ "$(grep -Fc 'validate_windows_result_path "$local_result"' "$ROOT/lib/windows-cape-agent.sh")" -eq 2 ]]

# Prove runtime identity gating against a tiny local CAPE-Agent-shaped endpoint.
TMP_AGENT="$(mktemp -d)"
cat >"$TMP_AGENT/server.py" <<'PY'
import json,sys
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        if self.path != "/":
            self.send_response(404); self.end_headers(); return
        b=json.dumps({"message":"CAPE Agent!","version":"0.22","features":["execpy","largefile"],"is_user_admin":True}).encode()
        self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
srv=ThreadingHTTPServer(("127.0.0.1",0),H)
open(sys.argv[1],"w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$TMP_AGENT/server.py" "$TMP_AGENT/port" >/dev/null 2>&1 &
AGENT_PID=$!
for _ in {1..50}; do [[ -s "$TMP_AGENT/port" ]] && break; sleep 0.05; done
[[ -s "$TMP_AGENT/port" ]]
CAPE_AGENT_PORT="$(cat "$TMP_AGENT/port")"
source "$ROOT/lib/windows-cape-agent.sh"
[[ "$(cape_agent_probe 127.0.0.1)" == 0.22 ]]
kill "$AGENT_PID" >/dev/null 2>&1 || true
wait "$AGENT_PID" 2>/dev/null || true
rm -rf "$TMP_AGENT"

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

echo '[PASS] QGA -> approved WinRM -> verified CAPE Agent execpy -> safe-stop zero-touch policy and Windows safety gates'

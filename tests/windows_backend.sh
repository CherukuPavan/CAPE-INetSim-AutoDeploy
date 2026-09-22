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
a=s.index('if cape_agent_wait "$CAPE_MACHINE_IP" 180', w)
z=s.index('No supported zero-touch Windows control channel is available', a)
assert q < w < a < z
assert "WINDOWS_BACKEND_USED=cape-agent-execpy" in s
assert "WINDOWS_BACKEND_USED=manual-powershell" not in s[s.index("windows_select_live_backend()"):s.index("windows_configure_selected_backend()")]
PY

grep -q 'windows-cape-agent.sh' "$ROOT/install"
[[ -e "$ROOT/lib/windows-cape-agent.sh" ]]
grep -Fq '/execpy' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'async=yes' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq '/status' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'cape_agent_wait_async_result' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'cape_agent_candidate_ips' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'cape_agent_try_retrieve_any' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'CAPE_AGENT_CUTOVER_TIMEOUT' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'CAPE_AGENT_GUEST_TIMEOUT' "$ROOT/lib/windows-cape-agent.sh"
! grep -Fq -- '--max-time 700' "$ROOT/lib/windows-cape-agent.sh"
! grep -Fq ' 660' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq '/store' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq '/retrieve' "$ROOT/lib/windows-cape-agent.sh"
! grep -Fq '/execute' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'rc=50' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'cape_agent_remove_paths_any' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq '{"execpy","largefile"}' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'd.get("is_user_admin") is not True' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'subprocess.run(cmd' "$ROOT/tools/windows_agent_runner.py"
! grep -Fq 'shell=True' "$ROOT/tools/windows_agent_runner.py"

grep -q 'Get-WmiObject Win32_NetworkAdapterConfiguration' "$ROOT/windows/configure-inetsim.ps1"
grep -q 'Get-WmiObject Win32_IP4RouteTable' "$ROOT/windows/configure-inetsim.ps1"
grep -Fq "'interface','ipv4','set','address'" "$ROOT/windows/configure-inetsim.ps1"
grep -Fq "'interface','ipv4','set','dnsservers'" "$ROOT/windows/configure-inetsim.ps1"
grep -Fq "Write-Progress 'management-static'" "$ROOT/windows/configure-inetsim.ps1"
grep -Fq "Write-Progress 'isolated-static'" "$ROOT/windows/configure-inetsim.ps1"
grep -Fq "Write-Progress 'connectivity-validated'" "$ROOT/windows/configure-inetsim.ps1"
! grep -Fq '.EnableStatic(' "$ROOT/windows/configure-inetsim.ps1"
! grep -Fq '.SetDNSServerSearchOrder(' "$ROOT/windows/configure-inetsim.ps1"
! grep -Fq '$a.Disable()' "$ROOT/windows/configure-inetsim.ps1"
grep -q "route.exe delete 0.0.0.0" "$ROOT/windows/configure-inetsim.ps1"
grep -q "netsh interface ipv6 delete route" "$ROOT/windows/configure-inetsim.ps1"
grep -q 'routerdiscovery=disabled' "$ROOT/windows/configure-inetsim.ps1"
grep -q 'unexpected active network adapter' "$ROOT/windows/configure-inetsim.ps1"
grep -q '2606:4700:4700::1111' "$ROOT/windows/configure-inetsim.ps1"
grep -q 'System.Net.Sockets.TcpClient' "$ROOT/windows/configure-inetsim.ps1"
grep -q 'System.Net.Dns' "$ROOT/windows/configure-inetsim.ps1"
grep -q 'legacy_network_stack' "$ROOT/windows/configure-inetsim.ps1"
grep -q 'legacy_network_stack' "$ROOT/windows/verify-inetsim.ps1"
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
from urllib.parse import parse_qs

state={"retrieve":0,"saw_async":False}

class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def send_json(self,obj,code=200):
        b=json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        if self.path == "/":
            self.send_json({"status_code":200,"message":"CAPE Agent!","version":"0.22","features":["execpy","largefile"],"is_user_admin":True})
            return
        if self.path == "/status":
            self.send_json({"status_code":200,"message":"Analysis status","status":"running","description":""})
            return
        self.send_response(404); self.end_headers()
    def do_POST(self):
        n=int(self.headers.get("Content-Length","0") or "0")
        body=self.rfile.read(n).decode(errors="replace")
        form=parse_qs(body)
        if self.path == "/execpy":
            state["saw_async"] = form.get("async") == ["yes"]
            if not state["saw_async"]:
                self.send_json({"status_code":400,"message":"missing async"},400)
                return
            self.send_json({"status_code":200,"message":"Successfully spawned command","process_id":1234})
            return
        if self.path == "/retrieve":
            state["retrieve"] += 1
            if state["retrieve"] < 2:
                self.send_response(404); self.end_headers(); return
            b=b'{"ok":true}\n'
            self.send_response(200)
            self.send_header("Content-Type","application/octet-stream")
            self.send_header("Content-Length",str(len(b)))
            self.end_headers()
            self.wfile.write(b)
            return
        self.send_response(404); self.end_headers()

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
cape_agent_execpy_async 127.0.0.1 'C:\Windows\Temp\runner.py' "$TMP_AGENT/execpy.log"
grep -Fq '"process_id": 1234' "$TMP_AGENT/execpy.log"
# Simulate the management path disappearing during reconfiguration: the mock
# server is bound only to 127.0.0.1, while 127.0.0.2 is supplied as primary.
# Result retrieval must transparently fall through to the alternate path.
cape_agent_wait_async_result 127.0.0.2 127.0.0.1 'C:\Windows\Temp\result.json' "$TMP_AGENT/result.json" "$TMP_AGENT/execpy.log" 10
grep -Fq '"ok":true' "$TMP_AGENT/result.json"
grep -Fq 'via=127.0.0.1' "$TMP_AGENT/execpy.log"

CAPE_AGENT_GUEST_TIMEOUT=180
cape_agent_write_runner_config "$TMP_AGENT/runner.json" 'C:\Windows\Temp\script.ps1' -ResultPath 'C:\Windows\Temp\result.json'
python3 - "$TMP_AGENT/runner.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
assert d["timeout"] == 180
PY

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

cat >"$TMP/legacy-result.json" <<'EOF'
{
  "ok": true,
  "legacy_network_stack": true,
  "default_routes": 0,
  "ipv4_default_routes": 0,
  "ipv6_default_routes": 0,
  "ipv6_bindings_enabled": -1,
  "ipv6_router_discovery_disabled": true,
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
validate_windows_result_path "$TMP/legacy-result.json"

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

echo '[PASS] QGA -> approved WinRM -> async dual-path CAPE Agent execpy -> safe-stop zero-touch policy and Windows safety gates'

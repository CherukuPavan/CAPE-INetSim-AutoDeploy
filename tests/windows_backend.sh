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
grep -Fq '/store' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq '/retrieve' "$ROOT/lib/windows-cape-agent.sh"
! grep -Fq '/execute' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq -- '--data-urlencode "async=yes"' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'cape_agent_candidate_ips' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'cape_agent_try_retrieve_any' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'CAPE_AGENT_CUTOVER_TIMEOUT' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'CAPE_AGENT_GUEST_TIMEOUT' "$ROOT/lib/windows-cape-agent.sh"
! grep -Fq -- '--max-time 700' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'rc=50' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'cape_agent_remove_any "$remote_runner"' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq '{"execpy","largefile"}' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'd.get("is_user_admin") is not True' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'subprocess.run(cmd' "$ROOT/tools/windows_agent_runner.py"
! grep -Fq 'shell=True' "$ROOT/tools/windows_agent_runner.py"

# Network discovery remains WMI-compatible with legacy Windows, but mutations
# must not use the blocking WMI methods that hung the RC19 CAPE-Agent cutover.
grep -q 'Get-WmiObject Win32_NetworkAdapterConfiguration' "$ROOT/windows/configure-inetsim.ps1"
grep -q 'Get-WmiObject Win32_IP4RouteTable' "$ROOT/windows/configure-inetsim.ps1"
grep -Fq 'Invoke-NetshChecked' "$ROOT/windows/configure-inetsim.ps1"
grep -Fq "'gateway=none'" "$ROOT/windows/configure-inetsim.ps1"
grep -Fq "Set-Stage 'management-static-begin'" "$ROOT/windows/configure-inetsim.ps1"
! grep -Fq '.EnableStatic(' "$ROOT/windows/configure-inetsim.ps1"
! grep -Fq '.SetDNSServerSearchOrder(' "$ROOT/windows/configure-inetsim.ps1"
! grep -Fq '.Enable()' "$ROOT/windows/configure-inetsim.ps1"
! grep -Fq '.Disable()' "$ROOT/windows/configure-inetsim.ps1"
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

# Prove runtime identity gating, async /execpy launch, and dual-path result
# retrieval against a tiny local CAPE-Agent-shaped endpoint.
TMP_AGENT="$(mktemp -d)"
cat >"$TMP_AGENT/server.py" <<'PY'
import json,sys
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.parse import parse_qs

seen=sys.argv[2]
def send_json(h,obj,code=200):
    b=json.dumps(obj).encode()
    h.send_response(code)
    h.send_header("Content-Type","application/json")
    h.send_header("Content-Length",str(len(b)))
    h.end_headers()
    h.wfile.write(b)

class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        if self.path == "/":
            send_json(self,{"message":"CAPE Agent!","version":"0.22","features":["execpy","largefile"],"is_user_admin":True,"status_code":200})
            return
        if self.path == "/status":
            send_json(self,{"message":"Analysis status","status":"complete","description":"","status_code":200})
            return
        self.send_response(404); self.end_headers()
    def do_POST(self):
        n=int(self.headers.get("Content-Length","0") or 0)
        raw=self.rfile.read(n).decode("utf-8","replace")
        with open(seen,"a",encoding="utf-8") as fp:
            fp.write(self.path+" "+raw+"\n")
        form=parse_qs(raw)
        if self.path == "/execpy":
            if form.get("async") != ["yes"]:
                send_json(self,{"status_code":400,"message":"async missing"},400)
                return
            send_json(self,{"status_code":200,"message":"Successfully spawned command","process_id":1234})
            return
        if self.path == "/retrieve":
            body=b'{"ok":true}'
            self.send_response(200)
            self.send_header("Content-Type","application/octet-stream")
            self.send_header("Content-Length",str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/remove":
            send_json(self,{"status_code":200,"message":"removed"})
            return
        self.send_response(404); self.end_headers()

srv=ThreadingHTTPServer(("127.0.0.1",0),H)
open(sys.argv[1],"w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$TMP_AGENT/server.py" "$TMP_AGENT/port" "$TMP_AGENT/seen" >/dev/null 2>&1 &
AGENT_PID=$!
for _ in {1..50}; do [[ -s "$TMP_AGENT/port" ]] && break; sleep 0.05; done
[[ -s "$TMP_AGENT/port" ]]
CAPE_AGENT_PORT="$(cat "$TMP_AGENT/port")"
source "$ROOT/lib/windows-cape-agent.sh"
[[ "$(cape_agent_probe 127.0.0.1)" == 0.22 ]]
cape_agent_execpy_async 127.0.0.1 'C:\Windows\Temp\runner.py' "$TMP_AGENT/launch.json"
grep -Fq 'Successfully spawned command' "$TMP_AGENT/launch.json"
grep -Fq 'async=yes' "$TMP_AGENT/seen"

CAPE_AGENT_ACTIVE_IP=""
cape_agent_try_retrieve_any 'C:\Windows\Temp\result.json' "$TMP_AGENT/result.json" 127.0.0.2 127.0.0.1
[[ "$CAPE_AGENT_ACTIVE_IP" == 127.0.0.1 ]]
grep -Fq '"ok":true' "$TMP_AGENT/result.json"

CAPE_AGENT_GUEST_TIMEOUT=180
cape_agent_write_runner_config "$TMP_AGENT/runner.json" 'C:\Windows\Temp\script.ps1' -ResultPath 'C:\Windows\Temp\result.json'
python3 - "$TMP_AGENT/runner.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
assert d["timeout"] == 180
assert d["script"].endswith("script.ps1")
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

echo '[PASS] QGA -> approved WinRM -> async dual-path CAPE Agent execpy -> safe-stop policy and Windows safety gates'

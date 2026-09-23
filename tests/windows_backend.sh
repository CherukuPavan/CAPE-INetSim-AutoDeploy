#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"

python3 -m py_compile "$ROOT/tools/winrm_exec.py" "$ROOT/tools/windows_agent_runner.py" "$ROOT/tools/windows_agent_finalize.py" "$ROOT/tools/windows_agent_poweroff.py"
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
a=s.index('if cape_agent_wait "$CAPE_MACHINE_IP" "$WINDOWS_CONTROL_BOOT_TIMEOUT"', w)
z=s.index('No supported zero-touch Windows control channel is available', a)
assert q < w < a < z
assert "WINDOWS_BACKEND_USED=cape-agent-execpy" in s
assert "WINDOWS_BACKEND_USED=manual-powershell" not in s[s.index("windows_select_live_backend()"):s.index("windows_configure_selected_backend()")]
assert 'WINDOWS_CONTROL_BOOT_TIMEOUT="${WINDOWS_CONTROL_BOOT_TIMEOUT:-300}"' in s
power=s[s.index("windows_poweroff_selected_backend()"):s.index("windows_manual_callback_command()")]
assert 'cape-agent-execpy)' in power
assert 'windows_poweroff_via_cape_agent "$CAPE_MACHINE_IP"' in power
PY

grep -q 'windows-cape-agent.sh' "$ROOT/install"
[[ -e "$ROOT/lib/windows-cape-agent.sh" ]]
grep -Fq '/execpy' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq '/store' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq '/retrieve' "$ROOT/lib/windows-cape-agent.sh"
! grep -Fq '/execute' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'cape_agent_prepare_client_identity' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq -- '--interface "$CAPE_AGENT_CLIENT_IP"' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'cape_agent_execpy_sync' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'cape_agent_run_powershell_sync' "$ROOT/lib/windows-cape-agent.sh"
[[ "$(grep -Fc 'async=yes' "$ROOT/lib/windows-cape-agent.sh")" -eq 1 ]]
grep -Fq 'cape_agent_execpy_async_detached' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'cape_agent_finalize_isolated_control' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'cape_agent_status' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'cape_agent_reap_async_state' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'Previous CAPE Agent async job ended in terminal state' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'windows_poweroff_via_cape_agent' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'tools/windows_agent_poweroff.py' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'Windows shut down through CAPE Agent guest command' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'refusing forced snapshot' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'local tmp="${log_file}.tmp.${BASHPID:-$}"' "$ROOT/lib/windows-cape-agent.sh"
! grep -Fq 'local tmp="${log_file}.tmp.$"' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'cape_agent_wait_async_success' "$ROOT/lib/windows-cape-agent.sh"
! grep -Fq 'cape_agent_wait_async_result' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq '{"execpy","largefile","pinning"}' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'd.get("is_user_admin") is not True' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'windows/stage-isolated-control.ps1' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'cape_agent_wait "$fake_ip" 60' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'control_path=management-finalized' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'CAPE Agent PowerShell execution failed' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'cape_agent_decode_execpy_log' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'cape_agent_extract_runner_envelope' "$ROOT/lib/windows-cape-agent.sh"
grep -Fq 'CAPE_INETSIM_RUNNER_V1:' "$ROOT/tools/windows_agent_runner.py"
grep -Fq 'result_present' "$ROOT/tools/windows_agent_runner.py"

[[ -f "$ROOT/windows/stage-isolated-control.ps1" ]]
grep -Fq 'PinnedClientIP' "$ROOT/windows/stage-isolated-control.ps1"
grep -Fq 'IsolatedGatewayIP' "$ROOT/windows/stage-isolated-control.ps1"
grep -Fq 'route.exe -p add $PinnedClientIP' "$ROOT/windows/stage-isolated-control.ps1"
grep -Fq 'remoteip=' "$ROOT/windows/stage-isolated-control.ps1"
grep -Fq 'pinned_client_ip=$PinnedClientIP' "$ROOT/windows/stage-isolated-control.ps1"
grep -Fq 'refusing to overwrite pre-existing /32 route' "$ROOT/windows/stage-isolated-control.ps1"
grep -Fq 'refusing to replace pre-existing Windows Firewall rule' "$ROOT/windows/stage-isolated-control.ps1"
! grep -Fq 'ManagementIP' "$ROOT/windows/stage-isolated-control.ps1"
[[ -f "$ROOT/tools/windows_agent_finalize.py" ]]
grep -Fq 'delay_seconds' "$ROOT/tools/windows_agent_finalize.py"
grep -Fq 'route.exe' "$ROOT/tools/windows_agent_finalize.py"
grep -Fq 'CAPE-INetSim-AutoDeploy isolated control' "$ROOT/tools/windows_agent_finalize.py"
[[ -f "$ROOT/tools/windows_agent_poweroff.py" ]]
grep -Fq 'Path(__file__).unlink()' "$ROOT/tools/windows_agent_poweroff.py"
grep -Fq '"shutdown.exe", "/s", "/t", "0", "/f"' "$ROOT/tools/windows_agent_poweroff.py"
python3 - "$ROOT/tools/windows_agent_poweroff.py" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()
assert s.index("Path(__file__).unlink()") < s.index("time.sleep(2)") < s.index('"shutdown.exe"')
PY

python3 - "$ROOT/lib/windows-cape-agent.sh" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()
f=s.index("windows_configure_via_cape_agent()")
body=s[f:s.index("windows_verify_via_cape_agent()",f)]
prepare=body.index('cape_agent_prepare_client_identity "$management_ip"')
stage=body.index("windows/stage-isolated-control.ps1")
prove=body.index('cape_agent_wait "$fake_ip" 60')
full=body.index("windows/configure-inetsim.ps1")
finalize=body.index('cape_agent_finalize_isolated_control "$fake_ip" "$management_ip"')
assert prepare < stage < prove < full < finalize
assert 'cape_agent_run_powershell_sync \\\n    "$management_ip"' in body
assert 'cape_agent_run_powershell_sync \\\n    "$fake_ip"' in body
assert '-PinnedClientIP "$CAPE_AGENT_CLIENT_IP"' in body
assert '-IsolatedGatewayIP "$BRIDGE_IP"' in body
verify=s[s.index("windows_verify_via_cape_agent()"):]
assert 'cape_agent_wait "$management_ip" 60' in verify
assert 'cape_agent_wait "$fake_ip"' not in verify
assert '-PinnedClientIP "$CAPE_AGENT_CLIENT_IP"' in verify
PY

grep -Fq 'proc = subprocess.run(' "$ROOT/tools/windows_agent_runner.py"
! grep -Fq 'shell=True' "$ROOT/tools/windows_agent_runner.py"

grep -q 'Get-WmiObject Win32_NetworkAdapterConfiguration' "$ROOT/windows/configure-inetsim.ps1"
grep -q 'Get-WmiObject Win32_IP4RouteTable' "$ROOT/windows/configure-inetsim.ps1"
grep -Fq "'interface','ipv4','set','address'" "$ROOT/windows/configure-inetsim.ps1"
grep -Fq "'interface','ipv4','set','dnsservers'" "$ROOT/windows/configure-inetsim.ps1"
grep -Fq "Write-Progress 'management-static'" "$ROOT/windows/configure-inetsim.ps1"
grep -Fq "Write-Progress 'isolated-static'" "$ROOT/windows/configure-inetsim.ps1"
grep -Fq '$isolatedAlreadyStaged' "$ROOT/windows/configure-inetsim.ps1"
grep -Fq 'Ensure-TemporaryControlRoute' "$ROOT/windows/configure-inetsim.ps1"
grep -Fq "Write-Progress 'control-route-proven'" "$ROOT/windows/configure-inetsim.ps1"
grep -Fq "Write-Progress 'isolated-static-preserved'" "$ROOT/windows/configure-inetsim.ps1"
python3 - "$ROOT/windows/configure-inetsim.ps1" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()
p=s.index("$isolatedAlreadyStaged=")
pres=s.index("Write-Progress 'isolated-static-preserved'",p)
elsepos=s.index("} else {",p)
setaddr=s.index("'interface','ipv4','set','address'",elsepos)
assert p < pres < elsepos < setaddr
PY
grep -Fq "Write-Progress 'connectivity-validated'" "$ROOT/windows/configure-inetsim.ps1"
! grep -Fq '.EnableStatic(' "$ROOT/windows/configure-inetsim.ps1"
! grep -Fq '.SetDNSServerSearchOrder(' "$ROOT/windows/configure-inetsim.ps1"
! grep -Fq '$a.Disable()' "$ROOT/windows/configure-inetsim.ps1"
grep -Fq 'function Remove-Default4' "$ROOT/windows/configure-inetsim.ps1"
grep -Fq '$route.Delete()' "$ROOT/windows/configure-inetsim.ps1"
grep -Fq '$routes=@(Get-Default4)' "$ROOT/windows/configure-inetsim.ps1"
grep -Fq '$defaults4=@(Get-Default4)' "$ROOT/windows/configure-inetsim.ps1"
grep -Fq '$defaults6=@(Get-Default6Lines)' "$ROOT/windows/configure-inetsim.ps1"
grep -Fq '$defaults4=@(Get-Default4)' "$ROOT/windows/verify-inetsim.ps1"
grep -Fq '$defaults6=@(Get-Default6Lines)' "$ROOT/windows/verify-inetsim.ps1"
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
grep -Fq 'temporary_control_routes' "$ROOT/windows/verify-inetsim.ps1"
grep -Fq 'isolated_agent_rules' "$ROOT/windows/verify-inetsim.ps1"
grep -Fq 'HNetCfg.FwPolicy2' "$ROOT/windows/verify-inetsim.ps1"
grep -Fq 'function Escape-JsonString' "$ROOT/windows/configure-inetsim.ps1"
grep -Fq 'function Convert-SimpleJsonValue' "$ROOT/windows/configure-inetsim.ps1"
grep -Fq 'function Escape-JsonString' "$ROOT/windows/verify-inetsim.ps1"
grep -Fq 'function Escape-JsonString' "$ROOT/windows/stage-isolated-control.ps1"
grep -Fq "System.Web.Script.Serialization.JavaScriptSerializer" "$ROOT/windows/configure-inetsim.ps1"
python3 - "$ROOT/windows/configure-inetsim.ps1" "$ROOT/windows/verify-inetsim.ps1" "$ROOT/windows/stage-isolated-control.ps1" <<'PY'
import sys
for p in sys.argv[1:]:
    s=open(p,encoding="utf-8").read()
    w=s.index("function Write-Result")
    # Result serialization itself must never pass runtime exception/WMI wrappers
    # to JavaScriptSerializer on PowerShell 2.
    end=s.find("\nfunction ", w+1)
    if end < 0:
        end=len(s)
    body=s[w:end]
    assert "JavaScriptSerializer" not in body, p
    assert "Convert-SimpleJsonValue" in s, p
    assert "Escape-JsonString" in s, p
cfg=open(sys.argv[1],encoding="utf-8").read()
assert "(Get-Default4).Count" not in cfg
assert "$defaults4=Get-Default4" not in cfg
assert "$defaults6=Get-Default6Lines" not in cfg
ver=open(sys.argv[2],encoding="utf-8").read()
assert "$defaults4=Get-Default4" not in ver
assert "$defaults6=Get-Default6Lines" not in ver
PY
grep -Fq 'validate_windows_result_path "$local_result"' "$ROOT/lib/windows-qga.sh"
[[ "$(grep -Fc 'validate_windows_result_path "$local_result"' "$ROOT/lib/windows-winrm.sh")" -eq 2 ]]
[[ "$(grep -Fc 'validate_windows_result_path "$local_result"' "$ROOT/lib/windows-cape-agent.sh")" -eq 2 ]]

# CAPE Agent 0.22 pins requests to the CAPE host client IP. Prove that an
# isolated-path request can keep that same source identity with curl --interface.
TMP_AGENT="$(mktemp -d)"
cat >"$TMP_AGENT/server.py" <<'PY'
import base64,json,sys
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.parse import parse_qs

seen=sys.argv[2]
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def send_json(self,obj,code=200):
        b=json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def mark(self):
        with open(seen,"a",encoding="utf-8") as fp:
            fp.write(self.client_address[0]+" "+self.path+"\n")
    def do_GET(self):
        self.mark()
        if self.path == "/":
            self.send_json({
                "status_code":200,"message":"CAPE Agent!","version":"0.22",
                "features":["execpy","largefile","pinning"],"is_user_admin":True
            })
            return
        self.send_response(404); self.end_headers()
    def do_POST(self):
        self.mark()
        n=int(self.headers.get("Content-Length","0") or 0)
        raw=self.rfile.read(n).decode("utf-8","replace")
        form=parse_qs(raw)
        if self.path == "/execpy":
            if "async" in form:
                self.send_json({"error_code":400,"message":"async forbidden"},400)
                return
            result=b'{"ok":true,"from":"runner-envelope"}\n'
            env={
                "schema":1,
                "returncode":0,
                "stdout_b64":base64.b64encode(b"runner ok\n").decode(),
                "stderr_b64":"",
                "result_present":True,
                "result_b64":base64.b64encode(result).decode(),
                "runner_error":""
            }
            payload=base64.b64encode(json.dumps(env,separators=(",",":")).encode()).decode()
            # RC23 guest compatibility shape: HTTP 200 success with no
            # status_code field; stdout is not Agent-wrapped base64.
            self.send_json({
                "message":"Successfully executed command",
                "stdout":"CAPE_INETSIM_RUNNER_V1:"+payload+"\n",
                "stderr":""
            })
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

WINDOWS_FAKE_IP=""
CAPE_AGENT_CLIENT_IP=""
[[ "$(cape_agent_probe 127.0.0.1)" == 0.22 ]]

WINDOWS_FAKE_IP=127.0.0.1
CAPE_AGENT_CLIENT_IP=127.0.0.2
cape_agent_execpy_sync 127.0.0.1 'C:\Windows\Temp\runner.py' "$TMP_AGENT/execpy.json" "$TMP_AGENT/result.json"
grep -Fq 'runner ok' "$TMP_AGENT/execpy.txt"
grep -Fq 'runner_returncode=0' "$TMP_AGENT/execpy.txt"
grep -Fq '"from":"runner-envelope"' "$TMP_AGENT/result.json"
grep -Fq '127.0.0.2 /execpy' "$TMP_AGENT/seen"
! grep -Fq 'status_code' "$TMP_AGENT/execpy.json"
! grep -Fq 'async' "$TMP_AGENT/execpy.json"

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
  "temporary_control_routes": 0,
  "isolated_agent_rules": 0,
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

cp "$TMP/legacy-result.json" "$TMP/cleanup-result.json"
python3 - "$TMP/cleanup-result.json" <<'PY'
import json,sys
p=sys.argv[1]
d=json.load(open(p))
d["temporary_control_routes"]=1
json.dump(d,open(p,"w"))
PY
if validate_windows_result_path "$TMP/cleanup-result.json" >/dev/null 2>&1; then
  echo 'Windows validator accepted a lingering temporary control route' >&2
  exit 1
fi

echo '[PASS] QGA -> approved WinRM -> pinned-client synchronous CAPE Agent isolated cutover -> Windows safety gates'

#!/usr/bin/env bash

CAPE_AGENT_PORT="${CAPE_AGENT_PORT:-8000}"
CAPE_AGENT_TIMEOUT="${CAPE_AGENT_TIMEOUT:-3}"

cape_agent_url() { printf 'http://%s:%s' "$1" "$CAPE_AGENT_PORT"; }

cape_agent_probe() {
  local ip="$1" body
  body="$(curl -fsS --max-time "$CAPE_AGENT_TIMEOUT" "$(cape_agent_url "$ip")/" 2>/dev/null)" || return 1
  python3 - "$body" <<'PY'
import json,sys
try: d=json.loads(sys.argv[1])
except Exception: raise SystemExit(1)
features=set(d.get('features') or [])
if not d.get('is_user_admin'): raise SystemExit(2)
if not {'execute','largefile'}.issubset(features): raise SystemExit(3)
print(d.get('version','unknown'))
PY
}

cape_agent_wait() {
  local ip="$1" timeout="${2:-120}" i version
  for ((i=0;i<timeout;i+=2)); do
    if version="$(cape_agent_probe "$ip" 2>/dev/null)"; then
      CAPE_AGENT_VERSION="$version"
      return 0
    fi
    sleep 2
  done
  return 1
}

cape_agent_store() {
  local ip="$1" local_file="$2" remote_path="$3"
  curl -fsS --max-time 30 -F "filepath=$remote_path" -F "file=@$local_file" "$(cape_agent_url "$ip")/store" >/dev/null
}

cape_agent_execute() {
  local ip="$1" command="$2"
  curl -fsS --max-time 180 --data-urlencode "command=$command" --data-urlencode "encoding=base64" "$(cape_agent_url "$ip")/execute"
}

cape_agent_retrieve() {
  local ip="$1" remote_path="$2" local_file="$3"
  curl -fsS --max-time 30 --data-urlencode "filepath=$remote_path" "$(cape_agent_url "$ip")/retrieve" >"$local_file"
}

cape_agent_remove() {
  local ip="$1" remote_path="$2"
  curl -fsS --max-time 20 --data-urlencode "path=$remote_path" "$(cape_agent_url "$ip")/remove" >/dev/null || true
}

windows_configure_via_cape_agent() {
  local guest_ip="$1" isolated_mac="$2" fake_ip="$3" prefix="$4" dns_ip="$5" result_ip="$6" result_port="$7" control_host_ip="$8"
  local ps1="$AUTODEPLOY_ROOT/windows/configure-inetsim.ps1"
  local remote_ps='C:\Windows\Temp\cape-inetsim-autodeploy.ps1'
  local remote_result='C:\Windows\Temp\cape-inetsim-autodeploy-result.json'
  local local_result="$AD_LOG_ROOT/${DEPLOYMENT_ID}-windows-result.json"

  [[ -f "$ps1" ]] || { fail "Windows configuration script missing"; return 1; }
  cape_agent_wait "$guest_ip" 180 || { fail "CAPE Agent did not become available/admin on $guest_ip"; return 1; }
  cape_agent_store "$guest_ip" "$ps1" "$remote_ps"

  local command
  printf -v command 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%s" -ManagementIP "%s" -IsolatedMac "%s" -FakeIP "%s" -PrefixLength %s -DnsIP "%s" -ResultServerIP "%s" -ResultServerPort %s -ControlHostIP "%s" -ResultPath "%s"' "$remote_ps" "$guest_ip" "$isolated_mac" "$fake_ip" "$prefix" "$dns_ip" "$result_ip" "$result_port" "$control_host_ip" "$remote_result"

  cape_agent_execute "$guest_ip" "$command" >"$AD_LOG_ROOT/${DEPLOYMENT_ID}-cape-agent-execute.json"
  cape_agent_retrieve "$guest_ip" "$remote_result" "$local_result"

  python3 - "$local_result" <<'PY'
import json,sys
with open(sys.argv[1]) as f: d=json.load(f)
if not d.get('ok'):
    print(json.dumps(d,indent=2), file=sys.stderr)
    raise SystemExit(1)
print('WINDOWS_CONFIG_OK')
PY

  cape_agent_remove "$guest_ip" "$remote_ps"
  cape_agent_remove "$guest_ip" "$remote_result"
  state_record_resource "windows-config" "$DOMAIN" "configured-via-cape-agent" "yes" "isolated_mac=$isolated_mac fake_ip=$fake_ip"
}


windows_verify_via_cape_agent() {
  local guest_ip="$1" isolated_mac="$2" fake_ip="$3" dns_ip="$4" result_ip="$5" result_port="$6"
  local ps1="$AUTODEPLOY_ROOT/windows/verify-inetsim.ps1"
  local remote_ps='C:\Windows\Temp\cape-inetsim-autodeploy-verify.ps1'
  local remote_result='C:\Windows\Temp\cape-inetsim-autodeploy-verify-result.json'
  local local_result="$AD_LOG_ROOT/${DEPLOYMENT_ID}-windows-verify.json"

  cape_agent_wait "$guest_ip" 120 || { fail "CAPE Agent unavailable for Windows verification"; return 1; }
  cape_agent_store "$guest_ip" "$ps1" "$remote_ps"
  local command
  printf -v command 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%s" -ManagementIP "%s" -IsolatedMac "%s" -FakeIP "%s" -DnsIP "%s" -ResultServerIP "%s" -ResultServerPort %s -ResultPath "%s"'     "$remote_ps" "$guest_ip" "$isolated_mac" "$fake_ip" "$dns_ip" "$result_ip" "$result_port" "$remote_result"
  cape_agent_execute "$guest_ip" "$command" >"$AD_LOG_ROOT/${DEPLOYMENT_ID}-cape-agent-verify-execute.json"
  cape_agent_retrieve "$guest_ip" "$remote_result" "$local_result"
  python3 - "$local_result" <<'PY'
import json,sys
with open(sys.argv[1],encoding="utf-8-sig") as f: d=json.load(f)
if not d.get("ok"):
    print(json.dumps(d,indent=2),file=sys.stderr)
    raise SystemExit(1)
PY
  cape_agent_remove "$guest_ip" "$remote_ps"
  cape_agent_remove "$guest_ip" "$remote_result"
}

windows_poweroff_via_cape_agent() {
  local guest_ip="$1"
  cape_agent_execute "$guest_ip" 'shutdown.exe /s /t 0 /f' >/dev/null 2>&1 || true
}

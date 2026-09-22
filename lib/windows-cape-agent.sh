#!/usr/bin/env bash

CAPE_AGENT_PORT="${CAPE_AGENT_PORT:-8000}"
CAPE_AGENT_TIMEOUT="${CAPE_AGENT_TIMEOUT:-3}"

cape_agent_url() { printf 'http://%s:%s' "$1" "$CAPE_AGENT_PORT"; }

cape_agent_probe() {
  local ip="$1" body
  body="$(curl -fsS --max-time "$CAPE_AGENT_TIMEOUT" "$(cape_agent_url "$ip")/" 2>/dev/null)" || return 1
  python3 - "$body" <<'PY'
import json,sys
try:
    d=json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
if d.get("message") != "CAPE Agent!":
    raise SystemExit(2)
if d.get("is_user_admin") is not True:
    raise SystemExit(3)
features=set(d.get("features") or [])
if not {"execpy","largefile"}.issubset(features):
    raise SystemExit(4)
version=str(d.get("version") or "unknown")
print(version)
PY
}

cape_agent_wait() {
  local ip="$1" timeout="${2:-60}" elapsed=0 version
  while ((elapsed < timeout)); do
    if version="$(cape_agent_probe "$ip" 2>/dev/null)"; then
      CAPE_AGENT_VERSION="$version"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed+2))
  done
  return 1
}

cape_agent_store() {
  local ip="$1" local_file="$2" remote_path="$3"
  [[ -f "$local_file" ]] || return 1
  curl -fsS --max-time 30     -F "filepath=$remote_path"     -F "file=@$local_file"     "$(cape_agent_url "$ip")/store" >/dev/null
}

cape_agent_retrieve() {
  local ip="$1" remote_path="$2" local_file="$3" timeout="${4:-30}"
  curl -fsS --max-time "$timeout"     --data-urlencode "filepath=$remote_path"     "$(cape_agent_url "$ip")/retrieve" >"$local_file"
}

cape_agent_remove() {
  local ip="$1" remote_path="$2"
  curl -fsS --max-time 15     --data-urlencode "path=$remote_path"     "$(cape_agent_url "$ip")/remove" >/dev/null 2>&1 || true
}

cape_agent_execpy_async() {
  local ip="$1" remote_python="$2" log_file="$3"
  local response
  response="$(curl -fsS --max-time 20     --data-urlencode "filepath=$remote_python"     --data-urlencode "async=yes"     "$(cape_agent_url "$ip")/execpy")" || return 1
  printf '%s\n' "$response" >"$log_file"
  python3 - "$response" <<'PY'
import json,sys
try:
    d=json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
if int(d.get("status_code",0)) != 200:
    raise SystemExit(2)
if not str(d.get("process_id","")).isdigit():
    raise SystemExit(3)
PY
}

cape_agent_status() {
  local ip="$1" response
  response="$(curl -fsS --max-time 5 "$(cape_agent_url "$ip")/status" 2>/dev/null)" || return 1
  python3 - "$response" <<'PY'
import json,sys
try:
    d=json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
if int(d.get("status_code",0)) != 200:
    raise SystemExit(2)
status=str(d.get("status") or "")
if status not in {"init","running","complete","failed","exception"}:
    raise SystemExit(3)
exitcode=d.get("exitcode")
description=str(d.get("description") or "").replace("\n"," ").replace("|","/")
print(f"{status}|{'' if exitcode is None else exitcode}|{description}")
PY
}

cape_agent_wait_async_result() {
  local ip="$1" remote_result="$2" local_result="$3" log_file="$4" timeout="${5:-660}"
  local elapsed=0 status_line="" status="" exitcode="" description="" last_status=""
  local tmp="${local_result}.partial"
  rm -f "$tmp"

  while ((elapsed < timeout)); do
    if cape_agent_retrieve "$ip" "$remote_result" "$tmp" 5 >/dev/null 2>&1 && [[ -s "$tmp" ]]; then
      mv -f "$tmp" "$local_result"
      printf 'result=retrieved elapsed=%s\n' "$elapsed" >>"$log_file"
      return 0
    fi
    rm -f "$tmp"

    if status_line="$(cape_agent_status "$ip" 2>/dev/null)"; then
      IFS='|' read -r status exitcode description <<<"$status_line"
      if [[ "$status_line" != "$last_status" ]]; then
        printf 'status=%s elapsed=%s\n' "$status_line" "$elapsed" >>"$log_file"
        last_status="$status_line"
      fi
      case "$status" in
        failed|exception)
          # A failing PowerShell script writes its signed validation result
          # before exiting non-zero. Give that result one short race window.
          sleep 2
          elapsed=$((elapsed+2))
          if cape_agent_retrieve "$ip" "$remote_result" "$tmp" 5 >/dev/null 2>&1 && [[ -s "$tmp" ]]; then
            mv -f "$tmp" "$local_result"
            printf 'result=retrieved-after-%s elapsed=%s\n' "$status" "$elapsed" >>"$log_file"
            return 0
          fi
          rm -f "$tmp"
          return 2
          ;;
      esac
    fi

    sleep 2
    elapsed=$((elapsed+2))
  done

  rm -f "$tmp"
  return 3
}

cape_agent_write_runner_config() {
  local out="$1" remote_ps="$2"
  shift 2
  python3 - "$out" "$remote_ps" "$@" <<'PY'
import json,pathlib,sys
out,script,*args=sys.argv[1:]
doc={"schema":1,"script":script,"arguments":args,"timeout":600}
pathlib.Path(out).write_text(json.dumps(doc,indent=2)+"\n",encoding="utf-8")
PY
  chmod 0600 "$out"
}

cape_agent_run_powershell() {
  local ip="$1" ps1="$2" stem="$3" local_result="$4"
  shift 4
  local remote_ps="C:\\Windows\\Temp\\${stem}.ps1"
  local remote_runner="C:\\Windows\\Temp\\${stem}.py"
  local remote_cfg="C:\\Windows\\Temp\\${stem}.json"
  local remote_result="C:\\Windows\\Temp\\${stem}-result.json"
  local remote_progress="${remote_result}.progress"
  local cfg="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-${stem}.json"
  local log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-${stem}-cape-agent-execpy.json"
  local progress_log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-${stem}-progress.txt"

  cape_agent_write_runner_config "$cfg" "$remote_ps" "$@" -ResultPath "$remote_result"

  # Remove only known AutoDeploy temporary paths from a previous interrupted
  # attempt. This prevents a stale result from being accepted after async launch.
  cape_agent_remove "$ip" "$remote_ps"
  cape_agent_remove "$ip" "$remote_runner"
  cape_agent_remove "$ip" "$remote_cfg"
  cape_agent_remove "$ip" "$remote_result"
  cape_agent_remove "$ip" "$remote_progress"
  rm -f "$local_result" "$progress_log"

  # Network cutover must not be tied to one long-lived HTTP request. Launch the
  # runner asynchronously, then tolerate management-NIC link churn while polling
  # CAPE Agent and retrieving the signed result file when the guest settles.
  local rc=0
  if ! cape_agent_store "$ip" "$ps1" "$remote_ps"; then
    rc=50
  elif ! cape_agent_store "$ip" "$AUTODEPLOY_ROOT/tools/windows_agent_runner.py" "$remote_runner"; then
    rc=51
  elif ! cape_agent_store "$ip" "$cfg" "$remote_cfg"; then
    rc=52
  elif ! cape_agent_execpy_async "$ip" "$remote_runner" "$log"; then
    rc=53
  elif ! cape_agent_wait_async_result "$ip" "$remote_result" "$local_result" "$log" 660; then
    rc=55
  fi

  # Best-effort progress capture is diagnostic only and never changes the
  # safety decision. Validation still relies solely on the signed result JSON.
  cape_agent_retrieve "$ip" "$remote_progress" "$progress_log" 5 >/dev/null 2>&1 || rm -f "$progress_log"

  cape_agent_remove "$ip" "$remote_ps"
  cape_agent_remove "$ip" "$remote_runner"
  cape_agent_remove "$ip" "$remote_cfg"
  cape_agent_remove "$ip" "$remote_result"
  cape_agent_remove "$ip" "$remote_progress"
  rm -f "$cfg"
  return "$rc"
}

windows_configure_via_cape_agent() {
  local guest_ip="$1" isolated_mac="$2" fake_ip="$3" prefix="$4" dns_ip="$5" result_ip="$6" result_port="$7" control_host_ip="$8"
  local local_result="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-windows-result.json"
  cape_agent_wait "$guest_ip" 60 || { fail "CAPE Agent execpy/admin channel did not become available on $guest_ip"; return 1; }
  cape_agent_run_powershell     "$guest_ip" "$AUTODEPLOY_ROOT/windows/configure-inetsim.ps1" "cape-inetsim-autodeploy" "$local_result"     -ManagementIP "$guest_ip"     -IsolatedMac "$isolated_mac"     -FakeIP "$fake_ip"     -PrefixLength "$prefix"     -DnsIP "$dns_ip"     -ResultServerIP "$result_ip"     -ResultServerPort "$result_port"     -ControlHostIP "$control_host_ip"
  validate_windows_result_path "$local_result"
  WINDOWS_BACKEND_USED=cape-agent-execpy
  state_record_resource windows-config "$DOMAIN" configured-via-cape-agent-execpy yes "isolated_mac=$isolated_mac fake_ip=$fake_ip agent_version=${CAPE_AGENT_VERSION:-unknown}"
  state_write_atomic
}

windows_verify_via_cape_agent() {
  local guest_ip="$1" isolated_mac="$2" fake_ip="$3" dns_ip="$4" result_ip="$5" result_port="$6"
  local local_result="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-windows-verify.json"
  cape_agent_wait "$guest_ip" 30 || { fail "CAPE Agent unavailable for Windows safety verification"; return 1; }
  cape_agent_run_powershell     "$guest_ip" "$AUTODEPLOY_ROOT/windows/verify-inetsim.ps1" "cape-inetsim-autodeploy-verify" "$local_result"     -ManagementIP "$guest_ip"     -IsolatedMac "$isolated_mac"     -FakeIP "$fake_ip"     -DnsIP "$dns_ip"     -ResultServerIP "$result_ip"     -ResultServerPort "$result_port"
  validate_windows_result_path "$local_result"
}

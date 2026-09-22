#!/usr/bin/env bash

CAPE_AGENT_PORT="${CAPE_AGENT_PORT:-8000}"
CAPE_AGENT_TIMEOUT="${CAPE_AGENT_TIMEOUT:-3}"
CAPE_AGENT_CUTOVER_TIMEOUT="${CAPE_AGENT_CUTOVER_TIMEOUT:-240}"
CAPE_AGENT_GUEST_TIMEOUT="${CAPE_AGENT_GUEST_TIMEOUT:-180}"

cape_agent_url() { printf 'http://%s:%s' "$1" "$CAPE_AGENT_PORT"; }

cape_agent_probe() {
  local ip="$1" body
  body="$(curl -fsS --connect-timeout "$CAPE_AGENT_TIMEOUT" --max-time "$CAPE_AGENT_TIMEOUT" "$(cape_agent_url "$ip")/" 2>/dev/null)" || return 1
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
  curl -fsS --connect-timeout 3 --max-time 30     -F "filepath=$remote_path"     -F "file=@$local_file"     "$(cape_agent_url "$ip")/store" >/dev/null
}

cape_agent_retrieve() {
  local ip="$1" remote_path="$2" local_file="$3" timeout="${4:-30}"
  curl -fsS --connect-timeout 2 --max-time "$timeout"     --data-urlencode "filepath=$remote_path"     "$(cape_agent_url "$ip")/retrieve" >"$local_file"
}

cape_agent_remove() {
  local ip="$1" remote_path="$2" timeout="${3:-5}"
  curl -fsS --connect-timeout 2 --max-time "$timeout"     --data-urlencode "path=$remote_path"     "$(cape_agent_url "$ip")/remove" >/dev/null 2>&1
}

cape_agent_execpy_async() {
  local ip="$1" remote_python="$2" log_file="$3"
  local response
  response="$(curl -fsS --connect-timeout 3 --max-time 20     --data-urlencode "filepath=$remote_python"     --data-urlencode "async=yes"     "$(cape_agent_url "$ip")/execpy")" || return 1
  printf '%s\n' "$response" >"$log_file"
  python3 - "$response" <<'PY'
import json,sys
try:
    d=json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
if int(d.get("status_code",0)) != 200:
    raise SystemExit(2)
if "spawn" not in str(d.get("message","")).lower():
    raise SystemExit(3)
PY
}

cape_agent_status() {
  local ip="$1" timeout="${2:-3}"
  curl -fsS --connect-timeout 2 --max-time "$timeout" "$(cape_agent_url "$ip")/status"
}

cape_agent_candidate_ips() {
  local primary="$1" alternate="${2:-}"
  printf '%s\n' "$primary"
  if [[ -n "$alternate" && "$alternate" != "$primary" ]]; then
    printf '%s\n' "$alternate"
  fi
}

cape_agent_try_retrieve_any() {
  local remote_path="$1" local_file="$2" primary="$3" alternate="${4:-}"
  local ip tmp
  tmp="${local_file}.tmp.$$"
  rm -f "$tmp"
  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    rm -f "$tmp"
    if cape_agent_retrieve "$ip" "$remote_path" "$tmp" 3 >/dev/null 2>&1; then
      mv -f "$tmp" "$local_file"
      CAPE_AGENT_ACTIVE_IP="$ip"
      return 0
    fi
  done < <(cape_agent_candidate_ips "$primary" "$alternate")
  rm -f "$tmp"
  return 1
}

cape_agent_try_status_any() {
  local log_file="$1" primary="$2" alternate="${3:-}"
  local ip response status
  CAPE_AGENT_LAST_STATUS=""
  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    if response="$(cape_agent_status "$ip" 3 2>/dev/null)"; then
      printf '%s\t%s\n' "$ip" "$response" >>"$log_file"
      status="$(python3 - "$response" <<'PY'
import json,sys
try:
    d=json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
if int(d.get("status_code",0)) != 200:
    raise SystemExit(2)
print(str(d.get("status") or "").strip().lower())
PY
)" || status=""
      if [[ -n "$status" ]]; then
        CAPE_AGENT_ACTIVE_IP="$ip"
        CAPE_AGENT_LAST_STATUS="$status"
        return 0
      fi
    fi
  done < <(cape_agent_candidate_ips "$primary" "$alternate")
  return 1
}

cape_agent_remove_any() {
  local remote_path="$1" primary="$2" alternate="${3:-}"
  local ip
  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    if cape_agent_remove "$ip" "$remote_path" 3; then
      return 0
    fi
  done < <(cape_agent_candidate_ips "$primary" "$alternate")
  return 1
}

cape_agent_write_runner_config() {
  local out="$1" remote_ps="$2"
  shift 2
  python3 - "$out" "$remote_ps" "$CAPE_AGENT_GUEST_TIMEOUT" "$@" <<'PY'
import json,pathlib,sys
out,script,timeout,*args=sys.argv[1:]
doc={"schema":1,"script":script,"arguments":args,"timeout":int(timeout)}
pathlib.Path(out).write_text(json.dumps(doc,indent=2)+"\n",encoding="utf-8")
PY
  chmod 0600 "$out"
}

cape_agent_run_powershell() {
  local ip="$1" ps1="$2" stem="$3" local_result="$4"
  shift 4
  local alternate_ip="${WINDOWS_FAKE_IP:-}"
  local remote_ps="C:\\Windows\\Temp\\${stem}.ps1"
  local remote_runner="C:\\Windows\\Temp\\${stem}.py"
  local remote_cfg="C:\\Windows\\Temp\\${stem}.json"
  local remote_result="C:\\Windows\\Temp\\${stem}-result.json"
  local remote_progress="${remote_result}.progress.txt"
  local cfg="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-${stem}.json"
  local launch_log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-${stem}-cape-agent-launch.json"
  local status_log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-${stem}-cape-agent-status.log"
  local progress_log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-${stem}-guest-progress.log"
  local rc=0 result_ready=no deadline

  : >"$status_log"
  chmod 0600 "$status_log"
  cape_agent_write_runner_config "$cfg" "$remote_ps" "$@" -ResultPath "$remote_result"

  # Upload everything while the original CAPE management path is still known
  # good. The actual network-changing PowerShell is launched asynchronously so
  # CAPE Agent can return before that script reconfigures the very NIC carrying
  # this control connection.
  if ! cape_agent_store "$ip" "$ps1" "$remote_ps"; then
    rc=50
  elif ! cape_agent_store "$ip" "$AUTODEPLOY_ROOT/tools/windows_agent_runner.py" "$remote_runner"; then
    rc=51
  elif ! cape_agent_store "$ip" "$cfg" "$remote_cfg"; then
    rc=52
  elif ! cape_agent_execpy_async "$ip" "$remote_runner" "$launch_log"; then
    rc=53
  else
    deadline=$((SECONDS + CAPE_AGENT_CUTOVER_TIMEOUT))
    while ((SECONDS < deadline)); do
      # The management NIC may briefly reset while becoming static. Once the
      # isolated address exists the same CAPE Agent is reachable from the host
      # on that directly connected network too, so accept either safe control
      # path for result retrieval.
      if cape_agent_try_retrieve_any "$remote_result" "$local_result" "$ip" "$alternate_ip"; then
        result_ready=yes
        rc=0
        break
      fi

      if cape_agent_try_status_any "$status_log" "$ip" "$alternate_ip"; then
        if [[ "$CAPE_AGENT_LAST_STATUS" == failed ]]; then
          rc=55
          break
        fi
      fi
      sleep 2
    done

    if [[ "$result_ready" != yes && "$rc" -eq 0 ]]; then
      rc=56
    fi
  fi

  if [[ "$rc" -ne 0 ]]; then
    cape_agent_try_retrieve_any "$remote_progress" "$progress_log" "$ip" "$alternate_ip" >/dev/null 2>&1 || true
    case "$rc" in
      53) fail "CAPE Agent refused the asynchronous Windows cutover launch" ;;
      55) fail "CAPE Agent Windows cutover process failed before returning a result; progress log: $progress_log" ;;
      56) fail "Timed out waiting for Windows cutover result across management/isolated CAPE Agent paths; progress log: $progress_log" ;;
      *) fail "CAPE Agent Windows cutover transport failed (stage $rc)" ;;
    esac
  fi

  # Cleanup is best-effort and bounded. Try the original management address and
  # the new isolated address, so a transient management reset cannot add another
  # minute of blocking cleanup to a failed deployment.
  cape_agent_remove_any "$remote_ps" "$ip" "$alternate_ip" || true
  cape_agent_remove_any "$remote_runner" "$ip" "$alternate_ip" || true
  cape_agent_remove_any "$remote_cfg" "$ip" "$alternate_ip" || true
  cape_agent_remove_any "$remote_result" "$ip" "$alternate_ip" || true
  cape_agent_remove_any "$remote_progress" "$ip" "$alternate_ip" || true
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
  cape_agent_wait "$guest_ip" 30 || {
    # After cutover, a management-path reset is not fatal if the isolated host
    # path reaches the same verified CAPE Agent.
    cape_agent_wait "$fake_ip" 30 || { fail "CAPE Agent unavailable for Windows safety verification"; return 1; }
    guest_ip="$fake_ip"
  }
  cape_agent_run_powershell     "$guest_ip" "$AUTODEPLOY_ROOT/windows/verify-inetsim.ps1" "cape-inetsim-autodeploy-verify" "$local_result"     -ManagementIP "$CAPE_MACHINE_IP"     -IsolatedMac "$isolated_mac"     -FakeIP "$fake_ip"     -DnsIP "$dns_ip"     -ResultServerIP "$result_ip"     -ResultServerPort "$result_port"
  validate_windows_result_path "$local_result"
}

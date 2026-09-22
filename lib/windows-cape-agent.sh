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
  local ip="$1" remote_path="$2" timeout="${3:-3}"
  curl -fsS --connect-timeout 2 --max-time "$timeout"     --data-urlencode "path=$remote_path"     "$(cape_agent_url "$ip")/remove" >/dev/null 2>&1 || true
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
if not str(d.get("process_id","")).isdigit():
    raise SystemExit(3)
PY
}

cape_agent_status() {
  local ip="$1" timeout="${2:-3}" response
  response="$(curl -fsS --connect-timeout 2 --max-time "$timeout" "$(cape_agent_url "$ip")/status" 2>/dev/null)" || return 1
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

cape_agent_candidate_ips() {
  local primary="$1" alternate="${2:-}"
  printf '%s\n' "$primary"
  if [[ -n "$alternate" && "$alternate" != "$primary" ]]; then
    printf '%s\n' "$alternate"
  fi
}

cape_agent_try_retrieve_any() {
  local remote_result="$1" local_result="$2" primary="$3" alternate="${4:-}" timeout="${5:-3}"
  local ip tmp
  tmp="${local_result}.partial.$$"
  rm -f "$tmp"
  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    rm -f "$tmp"
    if cape_agent_retrieve "$ip" "$remote_result" "$tmp" "$timeout" >/dev/null 2>&1 && [[ -s "$tmp" ]]; then
      mv -f "$tmp" "$local_result"
      CAPE_AGENT_ACTIVE_IP="$ip"
      return 0
    fi
  done < <(cape_agent_candidate_ips "$primary" "$alternate")
  rm -f "$tmp"
  return 1
}

cape_agent_try_status_any() {
  local primary="$1" alternate="${2:-}" ip status_line
  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    if status_line="$(cape_agent_status "$ip" 3 2>/dev/null)"; then
      CAPE_AGENT_ACTIVE_IP="$ip"
      printf '%s|%s\n' "$ip" "$status_line"
      return 0
    fi
  done < <(cape_agent_candidate_ips "$primary" "$alternate")
  return 1
}

cape_agent_reap_async_any() {
  local primary="$1" alternate="${2:-}" timeout="${3:-10}"
  local elapsed=0 status_line="" active_ip="" status="" exitcode="" description=""
  while ((elapsed < timeout)); do
    if status_line="$(cape_agent_try_status_any "$primary" "$alternate" 2>/dev/null)"; then
      IFS='|' read -r active_ip status exitcode description <<<"$status_line"
      case "$status" in
        complete|failed|exception) return 0 ;;
      esac
    fi
    sleep 1
    elapsed=$((elapsed+1))
  done
  return 1
}

cape_agent_wait_async_result() {
  local primary="$1" alternate="$2" remote_result="$3" local_result="$4" log_file="$5" timeout="${6:-$CAPE_AGENT_CUTOVER_TIMEOUT}"
  local elapsed=0 status_line="" active_ip="" status="" exitcode="" description="" last_status=""

  rm -f "$local_result"
  while ((elapsed < timeout)); do
    if cape_agent_try_retrieve_any "$remote_result" "$local_result" "$primary" "$alternate" 3; then
      printf 'result=retrieved via=%s elapsed=%s\n' "${CAPE_AGENT_ACTIVE_IP:-unknown}" "$elapsed" >>"$log_file"
      # CAPE Agent keeps the async subprocess object until /status observes a
      # terminal state. Reap it before another async /execpy launch; otherwise
      # a two-stage network cutover can be rejected as "already running".
      cape_agent_reap_async_any "$primary" "$alternate" 10 >/dev/null 2>&1 || true
      return 0
    fi

    if status_line="$(cape_agent_try_status_any "$primary" "$alternate" 2>/dev/null)"; then
      IFS='|' read -r active_ip status exitcode description <<<"$status_line"
      if [[ "$status_line" != "$last_status" ]]; then
        printf 'status=%s via=%s exit=%s description=%s elapsed=%s\n' "$status" "$active_ip" "$exitcode" "$description" "$elapsed" >>"$log_file"
        last_status="$status_line"
      fi
      case "$status" in
        failed|exception)
          # A failing PowerShell script writes its validation result before
          # exiting non-zero. Give the result file one short race window.
          sleep 2
          elapsed=$((elapsed+2))
          if cape_agent_try_retrieve_any "$remote_result" "$local_result" "$primary" "$alternate" 3; then
            printf 'result=retrieved-after-%s via=%s elapsed=%s\n' "$status" "${CAPE_AGENT_ACTIVE_IP:-unknown}" "$elapsed" >>"$log_file"
            return 0
          fi
          return 2
          ;;
      esac
    fi

    sleep 2
    elapsed=$((elapsed+2))
  done
  return 3
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

cape_agent_remove_paths_any() {
  local primary="$1" alternate="$2"
  shift 2
  local remote ip
  for remote in "$@"; do
    while IFS= read -r ip; do
      [[ -n "$ip" ]] || continue
      cape_agent_remove "$ip" "$remote" 3
    done < <(cape_agent_candidate_ips "$primary" "$alternate")
  done
}

cape_agent_run_powershell() {
  local ip="$1" ps1="$2" stem="$3" local_result="$4"
  shift 4
  local management_ip="${CAPE_MACHINE_IP:-$ip}"
  local fake_ip="${WINDOWS_FAKE_IP:-}"
  local alternate_ip=""
  if [[ -n "$fake_ip" && "$ip" != "$fake_ip" ]]; then
    alternate_ip="$fake_ip"
  elif [[ -n "$management_ip" && "$ip" != "$management_ip" ]]; then
    alternate_ip="$management_ip"
  fi

  local remote_ps="C:\\Windows\\Temp\\${stem}.ps1"
  local remote_runner="C:\\Windows\\Temp\\${stem}.py"
  local remote_cfg="C:\\Windows\\Temp\\${stem}.json"
  local remote_result="C:\\Windows\\Temp\\${stem}-result.json"
  local remote_progress="${remote_result}.progress"
  local cfg="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-${stem}.json"
  local log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-${stem}-cape-agent-execpy.json"
  local progress_log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-${stem}-progress.txt"
  local wait_rc=0 rc=0

  cape_agent_write_runner_config "$cfg" "$remote_ps" "$@" -ResultPath "$remote_result"

  # Before launch the management path is known good, so clear only project-owned
  # temporary names there. This prevents a stale result from being accepted.
  cape_agent_remove_paths_any "$ip" "" "$remote_ps" "$remote_runner" "$remote_cfg" "$remote_result" "$remote_progress"
  rm -f "$local_result" "$progress_log"

  # Launch asynchronously so the HTTP request returns before the guest rewrites
  # its own management NIC. During cutover poll both the original CAPE address
  # and the new directly-connected isolated fake address; either path reaching
  # the same authenticated/admin CAPE Agent is sufficient to retrieve the
  # signed safety result.
  if ! cape_agent_store "$ip" "$ps1" "$remote_ps"; then
    rc=50
  elif ! cape_agent_store "$ip" "$AUTODEPLOY_ROOT/tools/windows_agent_runner.py" "$remote_runner"; then
    rc=51
  elif ! cape_agent_store "$ip" "$cfg" "$remote_cfg"; then
    rc=52
  elif ! cape_agent_execpy_async "$ip" "$remote_runner" "$log"; then
    rc=53
  else
    if cape_agent_wait_async_result "$ip" "$alternate_ip" "$remote_result" "$local_result" "$log" "$CAPE_AGENT_CUTOVER_TIMEOUT"; then
      rc=0
    else
      wait_rc=$?
      case "$wait_rc" in
        2) rc=55 ;;
        3) rc=56 ;;
        *) rc=57 ;;
      esac
    fi
  fi

  # Progress is diagnostic only; validation still relies solely on result JSON.
  cape_agent_try_retrieve_any "$remote_progress" "$progress_log" "$ip" "$alternate_ip" 3 >/dev/null 2>&1 || rm -f "$progress_log"

  # Cleanup is best-effort and strictly bounded on both possible control paths.
  cape_agent_remove_paths_any "$ip" "$alternate_ip" "$remote_ps" "$remote_runner" "$remote_cfg" "$remote_result" "$remote_progress"
  rm -f "$cfg"

  case "$rc" in
    0) ;;
    53) fail "CAPE Agent refused the asynchronous Windows cutover launch" ;;
    55) fail "Windows cutover process failed before returning a result; guest progress: $progress_log" ;;
    56) fail "Timed out waiting for Windows cutover result across management/isolated CAPE Agent paths; guest progress: $progress_log" ;;
    57) fail "Unexpected CAPE Agent cutover wait failure; guest progress: $progress_log" ;;
    *) fail "CAPE Agent Windows cutover transport failed (stage $rc)" ;;
  esac
  return "$rc"
}

validate_cape_agent_stage_result_path() {
  local path="$1" fake_ip="$2" isolated_mac="$3" control_host_ip="$4"
  python3 - "$path" "$fake_ip" "$isolated_mac" "$control_host_ip" "$CAPE_AGENT_PORT" <<'PY'
import json,re,sys
path,fake_ip,want_mac,control_ip,port=sys.argv[1:]
try:
    d=json.load(open(path,encoding="utf-8-sig"))
except Exception as exc:
    raise SystemExit(f"invalid isolated-control stage result: {exc}")
norm=lambda s: re.sub(r"[^0-9A-Fa-f]","",str(s or "")).lower()
assert d.get("ok") is True, d.get("message") or "isolated-control stage failed"
assert d.get("stage")=="isolated-control-ready", "unexpected isolated-control stage marker"
assert str(d.get("fake_ip") or "")==fake_ip, "staged fake IP mismatch"
assert norm(d.get("isolated_mac"))==norm(want_mac), "staged isolated MAC mismatch"
assert str(d.get("control_host_ip") or "")==control_ip, "staged control host mismatch"
assert str(d.get("agent_port") or "")==port, "staged CAPE Agent port mismatch"
PY
}

windows_configure_via_cape_agent() {
  local management_ip="$1" isolated_mac="$2" fake_ip="$3" prefix="$4" dns_ip="$5" result_ip="$6" result_port="$7" control_host_ip="$8"
  local stage_result="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-windows-isolated-control-stage.json"
  local local_result="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-windows-result.json"

  cape_agent_wait "$management_ip" 60 || {
    fail "CAPE Agent execpy/admin channel did not become available on management IP $management_ip"
    return 1
  }

  # Stage only the isolated NIC first. Do not touch management addressing,
  # routing or DNS until the host has independently proved that CAPE Agent is
  # reachable over the isolated path. This removes the RC21 self-cutoff where
  # the management NIC was rewritten before the alternate control path existed.
  cape_agent_run_powershell \
    "$management_ip" "$AUTODEPLOY_ROOT/windows/stage-isolated-control.ps1" \
    "cape-inetsim-autodeploy-stage" "$stage_result" \
    -IsolatedMac "$isolated_mac" \
    -FakeIP "$fake_ip" \
    -PrefixLength "$prefix" \
    -ControlHostIP "$BRIDGE_IP" \
    -AgentPort "$CAPE_AGENT_PORT"
  validate_cape_agent_stage_result_path "$stage_result" "$fake_ip" "$isolated_mac" "$BRIDGE_IP" || {
    fail "Windows isolated CAPE Agent staging result did not validate"
    return 1
  }

  cape_agent_wait "$fake_ip" 60 || {
    fail "Isolated CAPE Agent control path $fake_ip:$CAPE_AGENT_PORT did not become reachable; management networking was left unchanged"
    return 1
  }
  pass "Proved isolated CAPE Agent control path before management network hardening"

  # From here on control runs over the isolated NIC. The full safety script may
  # safely make the management NIC static/gateway-less without cutting off the
  # control channel that is carrying the operation.
  cape_agent_run_powershell \
    "$fake_ip" "$AUTODEPLOY_ROOT/windows/configure-inetsim.ps1" \
    "cape-inetsim-autodeploy" "$local_result" \
    -ManagementIP "$management_ip" \
    -IsolatedMac "$isolated_mac" \
    -FakeIP "$fake_ip" \
    -PrefixLength "$prefix" \
    -DnsIP "$dns_ip" \
    -ResultServerIP "$result_ip" \
    -ResultServerPort "$result_port" \
    -ControlHostIP "$control_host_ip"
  validate_windows_result_path "$local_result"
  WINDOWS_BACKEND_USED=cape-agent-execpy
  state_record_resource windows-config "$DOMAIN" configured-via-cape-agent-execpy yes \
    "isolated_mac=$isolated_mac fake_ip=$fake_ip control_path=isolated agent_version=${CAPE_AGENT_VERSION:-unknown}"
  state_write_atomic
}

windows_verify_via_cape_agent() {
  local management_ip="$1" isolated_mac="$2" fake_ip="$3" dns_ip="$4" result_ip="$5" result_port="$6"
  local control_ip=""
  local local_result="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-windows-verify.json"

  # Prefer the isolated path that was explicitly proved before management
  # hardening. Fall back to management only for compatibility with an already
  # configured guest whose isolated CAPE Agent rule was removed externally.
  if cape_agent_wait "$fake_ip" 30; then
    control_ip="$fake_ip"
  elif cape_agent_wait "$management_ip" 30; then
    control_ip="$management_ip"
  else
    fail "CAPE Agent unavailable on both isolated and management paths for Windows safety verification"
    return 1
  fi

  cape_agent_run_powershell \
    "$control_ip" "$AUTODEPLOY_ROOT/windows/verify-inetsim.ps1" \
    "cape-inetsim-autodeploy-verify" "$local_result" \
    -ManagementIP "$management_ip" \
    -IsolatedMac "$isolated_mac" \
    -FakeIP "$fake_ip" \
    -DnsIP "$dns_ip" \
    -ResultServerIP "$result_ip" \
    -ResultServerPort "$result_port"
  validate_windows_result_path "$local_result"
}


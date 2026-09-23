#!/usr/bin/env bash

CAPE_AGENT_PORT="${CAPE_AGENT_PORT:-8000}"
CAPE_AGENT_TIMEOUT="${CAPE_AGENT_TIMEOUT:-3}"
CAPE_AGENT_GUEST_TIMEOUT="${CAPE_AGENT_GUEST_TIMEOUT:-180}"
CAPE_AGENT_CLIENT_IP="${CAPE_AGENT_CLIENT_IP:-}"

cape_agent_url() { printf 'http://%s:%s' "$1" "$CAPE_AGENT_PORT"; }

cape_agent_route_source_ip() {
  local target="$1"
  ip -4 route get "$target" 2>/dev/null | awk '
    {
      for(i=1;i<=NF;i++){
        if($i=="src" && (i+1)<=NF){print $(i+1); exit}
      }
    }'
}

cape_agent_prepare_client_identity() {
  local management_ip="$1" source_ip
  source_ip="$(cape_agent_route_source_ip "$management_ip")"
  [[ -n "$source_ip" ]] || {
    fail "Could not derive the CAPE host source IP used to reach Windows management address $management_ip"
    return 1
  }
  CAPE_AGENT_CLIENT_IP="$source_ip"
}

cape_agent_curl() {
  local ip="$1"
  shift
  local -a source_args=()
  # CAPE 0.22 pins the Agent to the client IP used by CAPE. When controlling
  # the same Agent through its isolated address, preserve that exact client
  # identity instead of presenting the isolated bridge address as a new client.
  if [[ -n "${CAPE_AGENT_CLIENT_IP:-}" &&
        -n "${WINDOWS_FAKE_IP:-}" &&
        "$ip" == "$WINDOWS_FAKE_IP" ]]; then
    source_args=(--interface "$CAPE_AGENT_CLIENT_IP")
  fi
  curl "${source_args[@]}" "$@"
}

cape_agent_probe() {
  local ip="$1" body
  body="$(cape_agent_curl "$ip" -fsS --connect-timeout "$CAPE_AGENT_TIMEOUT" --max-time "$CAPE_AGENT_TIMEOUT" "$(cape_agent_url "$ip")/" 2>/dev/null)" || return 1
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
if not {"execpy","largefile","pinning"}.issubset(features):
    raise SystemExit(4)
print(str(d.get("version") or "unknown"))
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
  cape_agent_curl "$ip" -fsS --connect-timeout 3 --max-time 30 \
    -F "filepath=$remote_path" \
    -F "file=@$local_file" \
    "$(cape_agent_url "$ip")/store" >/dev/null
}

cape_agent_retrieve() {
  local ip="$1" remote_path="$2" local_file="$3" timeout="${4:-30}"
  cape_agent_curl "$ip" -fsS --connect-timeout 2 --max-time "$timeout" \
    --data-urlencode "filepath=$remote_path" \
    "$(cape_agent_url "$ip")/retrieve" >"$local_file"
}

cape_agent_remove() {
  local ip="$1" remote_path="$2" timeout="${3:-3}"
  cape_agent_curl "$ip" -fsS --connect-timeout 2 --max-time "$timeout" \
    --data-urlencode "path=$remote_path" \
    "$(cape_agent_url "$ip")/remove" >/dev/null 2>&1 || true
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

cape_agent_decode_execpy_log() {
  local json_log="$1" text_log="$2"
  python3 - "$json_log" "$text_log" <<'PY'
import base64,json,pathlib,sys
src,dst=sys.argv[1:]
lines=[]
try:
    d=json.load(open(src,encoding="utf-8"))
except Exception as exc:
    pathlib.Path(dst).write_text(f"invalid CAPE Agent execpy response: {exc}\n",encoding="utf-8")
    raise SystemExit
for k in ("message","description","error_code","status_code","exitcode"):
    if d.get(k) not in (None,""):
        lines.append(f"{k}={d.get(k)}")
for k in ("stdout","stderr"):
    v=d.get(k)
    if not v:
        continue
    raw=str(v)
    data=raw
    try:
        decoded=base64.b64decode(raw,validate=True).decode("utf-8","replace")
        if "CAPE_INETSIM_RUNNER_V1:" in decoded or decoded.strip():
            data=decoded
    except Exception:
        pass
    lines.append(f"{k}:\n{data}")
pathlib.Path(dst).write_text("\n".join(lines)+"\n",encoding="utf-8")
PY
}

cape_agent_extract_runner_envelope() {
  local json_log="$1" local_result="$2" text_log="$3"
  python3 - "$json_log" "$local_result" "$text_log" <<'PY'
import base64,json,pathlib,sys
src,result_path,text_path=sys.argv[1:]
prefix="CAPE_INETSIM_RUNNER_V1:"

try:
    outer=json.load(open(src,encoding="utf-8"))
except Exception as exc:
    with open(text_path,"a",encoding="utf-8") as fp:
        fp.write(f"runner_envelope_error=invalid agent JSON: {exc}\n")
    raise SystemExit(1)

stdout=outer.get("stdout")
if stdout is None:
    stdout=""
if isinstance(stdout,bytes):
    stdout=stdout.decode("utf-8","replace")
else:
    stdout=str(stdout)

candidates=[stdout]
try:
    candidates.append(base64.b64decode(stdout,validate=True).decode("utf-8","replace"))
except Exception:
    pass

payload=None
for text in candidates:
    for line in text.splitlines():
        if line.startswith(prefix):
            payload=line[len(prefix):].strip()
            break
    if payload:
        break

if not payload:
    with open(text_path,"a",encoding="utf-8") as fp:
        fp.write("runner_envelope_error=missing versioned runner envelope\n")
    raise SystemExit(2)

try:
    env=json.loads(base64.b64decode(payload,validate=True).decode("utf-8"))
except Exception as exc:
    with open(text_path,"a",encoding="utf-8") as fp:
        fp.write(f"runner_envelope_error=invalid envelope: {exc}\n")
    raise SystemExit(3)

def dec(name):
    try:
        return base64.b64decode(env.get(name,"") or "").decode("utf-8","replace")
    except Exception:
        return "<decode failed>"

with open(text_path,"a",encoding="utf-8") as fp:
    fp.write(f"runner_schema={env.get('schema')}\n")
    fp.write(f"runner_returncode={env.get('returncode')}\n")
    if env.get("runner_error"):
        fp.write(f"runner_error={env.get('runner_error')}\n")
    out=dec("stdout_b64")
    err=dec("stderr_b64")
    if out:
        fp.write("runner_stdout:\n"+out+("\n" if not out.endswith("\n") else ""))
    if err:
        fp.write("runner_stderr:\n"+err+("\n" if not err.endswith("\n") else ""))

result_present=env.get("result_present") is True
if result_present:
    try:
        result=base64.b64decode(env.get("result_b64","") or "",validate=True)
        pathlib.Path(result_path).write_bytes(result)
    except Exception as exc:
        with open(text_path,"a",encoding="utf-8") as fp:
            fp.write(f"runner_result_error={exc}\n")
        raise SystemExit(4)
else:
    pathlib.Path(result_path).unlink(missing_ok=True)

try:
    rc=int(env.get("returncode"))
except Exception:
    raise SystemExit(5)

# A valid result is required even when PowerShell exits non-zero; the caller
# can then surface the script's own structured error instead of a transport
# ambiguity.
if not result_present:
    raise SystemExit(6)
raise SystemExit(0 if rc == 0 else 7)
PY
}

cape_agent_execpy_sync() {
  local ip="$1" remote_python="$2" json_log="$3" local_result="$4"
  local text_log="${json_log%.json}.txt"
  local tmp="${json_log}.tmp.$$" http curl_rc=0
  rm -f "$tmp" "$json_log" "$text_log" "$local_result"

  # Do not trust CAPE Agent JSON schema for child success. Older agents return
  # HTTP 200 and omit status_code even when the child process exits non-zero.
  # The uploaded runner emits a versioned envelope containing the real
  # PowerShell return code, stdout/stderr and result JSON.
  http="$(cape_agent_curl "$ip" -sS --connect-timeout 3 \
      --max-time "$((CAPE_AGENT_GUEST_TIMEOUT + 30))" \
      -o "$tmp" -w '%{http_code}' \
      --data-urlencode "filepath=$remote_python" \
      --data-urlencode "encoding=base64" \
      "$(cape_agent_url "$ip")/execpy")" || curl_rc=$?

  [[ -f "$tmp" ]] && mv -f "$tmp" "$json_log" || : >"$json_log"
  cape_agent_decode_execpy_log "$json_log" "$text_log"
  printf 'http_status=%s\ncurl_rc=%s\n' "${http:-000}" "$curl_rc" >>"$text_log"

  ((curl_rc == 0)) || return 1
  cape_agent_extract_runner_envelope "$json_log" "$local_result" "$text_log"
}

cape_agent_status() {
  local ip="$1" timeout="${2:-5}"
  cape_agent_curl "$ip" -fsS --connect-timeout 2 --max-time "$timeout" \
    "$(cape_agent_url "$ip")/status"
}

cape_agent_reap_async_state() {
  local ip="$1" timeout="${2:-30}" elapsed=0 body="" status=""
  while ((elapsed < timeout)); do
    if body="$(cape_agent_status "$ip" 5 2>/dev/null)"; then
      status="$(python3 - "$body" <<'PY'
import json,sys
try:
    d=json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
print(str(d.get("status") or "").lower())
PY
)" || status=""
      case "$status" in
        complete|failed|exception|init) return 0 ;;
        running|"") ;;
        *)
          fail "Unexpected CAPE Agent async status: $status"
          return 1
          ;;
      esac
    fi
    sleep 1
    elapsed=$((elapsed+1))
  done
  fail "Timed out waiting for previous CAPE Agent async job to clear"
  return 1
}

cape_agent_wait_async_success() {
  local ip="$1" timeout="${2:-30}" elapsed=0 body="" status=""
  while ((elapsed < timeout)); do
    if body="$(cape_agent_status "$ip" 5 2>/dev/null)"; then
      status="$(python3 - "$body" <<'PY'
import json,sys
try:
    d=json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
print(str(d.get("status") or "").lower())
PY
)" || status=""
      case "$status" in
        complete) return 0 ;;
        failed|exception)
          fail "CAPE Agent detached job ended in terminal state: $status"
          return 1
          ;;
        running|init|"") ;;
        *)
          fail "Unexpected CAPE Agent detached-job status: $status"
          return 1
          ;;
      esac
    fi
    sleep 1
    elapsed=$((elapsed+1))
  done
  fail "Timed out waiting for CAPE Agent detached job to complete"
  return 1
}

cape_agent_execpy_async_detached() {
  local ip="$1" remote_python="$2" log_file="$3"
  local tmp="${log_file}.tmp.${BASHPID}" http curl_rc=0
  rm -f "$tmp" "$log_file"

  # CAPE Agent 0.22 keeps the previous async subprocess slot until /status is
  # polled. Reap any completed detached helper before launching another one.
  cape_agent_reap_async_state "$ip" 20 || return 1

  http="$(cape_agent_curl "$ip" -sS --connect-timeout 3 --max-time 20 \
      -o "$tmp" -w '%{http_code}' \
      --data-urlencode "filepath=$remote_python" \
      --data-urlencode "async=yes" \
      "$(cape_agent_url "$ip")/execpy")" || curl_rc=$?

  [[ -f "$tmp" ]] && mv -f "$tmp" "$log_file" || : >"$log_file"
  ((curl_rc == 0)) || return 1
  [[ "$http" == 200 ]] || return 1

  python3 - "$log_file" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding="utf-8"))
except Exception:
    raise SystemExit(1)
pid=d.get("process_id")
if not str(pid or "").isdigit():
    raise SystemExit(2)
msg=str(d.get("message") or "").lower()
if "spawn" not in msg and "execut" not in msg:
    raise SystemExit(3)
PY
}

cape_agent_finalize_isolated_control() {
  local isolated_ip="$1" management_ip="$2"
  local stem="cape-inetsim-autodeploy-finalize"
  local remote_py="C:\\Windows\\Temp\\${stem}.py"
  local remote_cfg="C:\\Windows\\Temp\\${stem}.json"
  local cfg="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-${stem}.json"
  local log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-${stem}-cape-agent-execpy.json"

  python3 - "$cfg" "$CAPE_AGENT_CLIENT_IP" <<'PY'
import json,pathlib,sys
path,client=sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    "schema":1,
    "pinned_client_ip":client,
    "delay_seconds":5
},indent=2)+"\n",encoding="utf-8")
PY
  chmod 0600 "$cfg"

  cape_agent_remove "$isolated_ip" "$remote_py" 2
  cape_agent_remove "$isolated_ip" "$remote_cfg" 2

  if ! cape_agent_store "$isolated_ip" "$AUTODEPLOY_ROOT/tools/windows_agent_finalize.py" "$remote_py"; then
    rm -f "$cfg"
    fail "Could not stage deferred CAPE Agent control-path finalizer"
    return 58
  fi
  if ! cape_agent_store "$isolated_ip" "$cfg" "$remote_cfg"; then
    rm -f "$cfg"
    fail "Could not stage deferred CAPE Agent finalizer configuration"
    return 59
  fi
  rm -f "$cfg"

  # The finalizer sleeps before deleting the temporary /32 route and Windows
  # Firewall rule. Async launch lets this HTTP response leave over the still-
  # valid isolated path before the route is removed.
  cape_agent_execpy_async_detached "$isolated_ip" "$remote_py" "$log" || {
    fail "CAPE Agent refused deferred isolated-control finalization"
    return 60
  }

  sleep 7
  cape_agent_wait "$management_ip" 45 || {
    fail "CAPE Agent did not return on the normal management path after isolated-control finalization"
    return 61
  }
  cape_agent_wait_async_success "$management_ip" 30 || {
    fail "CAPE Agent isolated-control finalizer did not complete cleanly"
    return 61
  }

  cape_agent_remove "$management_ip" "$remote_py" 3
  cape_agent_remove "$management_ip" "$remote_cfg" 3
  pass "Returned CAPE Agent control to the management path after Windows hardening"
}

windows_poweroff_via_cape_agent() {
  local management_ip="$1"
  local stem="cape-inetsim-autodeploy-poweroff"
  local remote_py="C:\\Windows\\Temp\\${stem}.py"
  local log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-${stem}-cape-agent-execpy.json"
  local state="" elapsed=0

  state="$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)"
  [[ "$state" == "shut off" ]] && return 0
  [[ "$state" == running ]] || {
    fail "Cannot request CAPE Agent poweroff from Windows domain state: ${state:-unknown}"
    return 62
  }

  cape_agent_prepare_client_identity "$management_ip" || return 62
  cape_agent_wait "$management_ip" 60 || {
    fail "CAPE Agent is unavailable on management IP $management_ip for guest-driven shutdown"
    return 62
  }

  cape_agent_remove "$management_ip" "$remote_py" 2
  cape_agent_store "$management_ip" "$AUTODEPLOY_ROOT/tools/windows_agent_poweroff.py" "$remote_py" || {
    fail "Could not stage CAPE Agent Windows shutdown helper"
    return 63
  }

  # ACPI-only virsh shutdown is not reliable on every sandbox image. Launch
  # shutdown.exe inside the guest, asynchronously, so the Agent can return the
  # spawn response before Windows tears down networking/processes.
  if cape_agent_execpy_async_detached "$management_ip" "$remote_py" "$log"; then
    while ((elapsed < 120)); do
      state="$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)"
      if [[ "$state" == "shut off" ]]; then
        pass "Windows shut down through CAPE Agent guest command"
        return 0
      fi
      sleep 2
      elapsed=$((elapsed+2))
    done
  else
    warn "CAPE Agent shutdown helper did not launch; trying libvirt ACPI shutdown fallback"
  fi

  # Last graceful fallback only. Never destroy the guest during normal
  # deployment because the working snapshot must be based on a clean shutdown.
  virsh shutdown "$DOMAIN" >/dev/null 2>&1 || true
  elapsed=0
  while ((elapsed < 90)); do
    state="$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)"
    if [[ "$state" == "shut off" ]]; then
      pass "Windows shut down through libvirt ACPI fallback"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed+2))
  done

  fail "Windows did not shut down after CAPE Agent guest shutdown and ACPI fallback; refusing forced snapshot"
  return 64
}

cape_agent_run_powershell_sync() {
  local ip="$1" ps1="$2" stem="$3" local_result="$4"
  shift 4
  local remote_ps="C:\\Windows\\Temp\\${stem}.ps1"
  local remote_runner="C:\\Windows\\Temp\\${stem}.py"
  local remote_cfg="C:\\Windows\\Temp\\${stem}.json"
  local remote_result="C:\\Windows\\Temp\\${stem}-result.json"
  local remote_progress="${remote_result}.progress"
  local cfg="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-${stem}.json"
  local exec_log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-${stem}-cape-agent-execpy.json"
  local exec_text="${exec_log%.json}.txt"
  local progress_log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-${stem}-progress.txt"
  local exec_rc=0 result_ok=no

  cape_agent_write_runner_config "$cfg" "$remote_ps" "$@" -ResultPath "$remote_result"
  cape_agent_remove "$ip" "$remote_ps" 2
  cape_agent_remove "$ip" "$remote_runner" 2
  cape_agent_remove "$ip" "$remote_cfg" 2
  cape_agent_remove "$ip" "$remote_result" 2
  cape_agent_remove "$ip" "$remote_progress" 2
  rm -f "$local_result" "$progress_log"

  if ! cape_agent_store "$ip" "$ps1" "$remote_ps"; then
    exec_rc=50
  elif ! cape_agent_store "$ip" "$AUTODEPLOY_ROOT/tools/windows_agent_runner.py" "$remote_runner"; then
    exec_rc=51
  elif ! cape_agent_store "$ip" "$cfg" "$remote_cfg"; then
    exec_rc=52
  elif ! cape_agent_execpy_sync "$ip" "$remote_runner" "$exec_log" "$local_result"; then
    exec_rc=53
  fi

  [[ -s "$local_result" ]] && result_ok=yes
  cape_agent_retrieve "$ip" "$remote_progress" "$progress_log" 5 >/dev/null 2>&1 || rm -f "$progress_log"

  cape_agent_remove "$ip" "$remote_ps" 2
  cape_agent_remove "$ip" "$remote_runner" 2
  cape_agent_remove "$ip" "$remote_cfg" 2
  cape_agent_remove "$ip" "$remote_result" 2
  cape_agent_remove "$ip" "$remote_progress" 2
  rm -f "$cfg"

  if [[ "$exec_rc" -ne 0 ]]; then
    fail "CAPE Agent PowerShell execution failed (stage $exec_rc); details: $exec_text"
    return "$exec_rc"
  fi
  [[ "$result_ok" == yes ]] || {
    fail "CAPE Agent PowerShell completed without a retrievable result; details: $exec_text"
    return 54
  }
}

validate_cape_agent_stage_result_path() {
  local path="$1" fake_ip="$2" isolated_mac="$3" client_ip="$4" gateway_ip="$5"
  python3 - "$path" "$fake_ip" "$isolated_mac" "$client_ip" "$gateway_ip" "$CAPE_AGENT_PORT" <<'PY'
import json,re,sys
path,fake_ip,want_mac,client_ip,gateway_ip,port=sys.argv[1:]
d=json.load(open(path,encoding="utf-8-sig"))
norm=lambda s: re.sub(r"[^0-9A-Fa-f]","",str(s or "")).lower()
assert d.get("ok") is True, d.get("message") or "isolated-control stage failed"
assert d.get("stage")=="isolated-control-ready"
assert str(d.get("fake_ip") or "")==fake_ip
assert norm(d.get("isolated_mac"))==norm(want_mac)
assert str(d.get("pinned_client_ip") or "")==client_ip
assert str(d.get("isolated_gateway_ip") or "")==gateway_ip
assert str(d.get("agent_port") or "")==port
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
  cape_agent_prepare_client_identity "$management_ip" || return 1

  # Stage the isolated adapter synchronously while management is untouched. The
  # guest installs a /32 route for the already-pinned CAPE client identity over
  # the isolated bridge, so later requests can arrive on the isolated NIC while
  # still appearing to CAPE Agent as the same approved client IP.
  cape_agent_run_powershell_sync \
    "$management_ip" "$AUTODEPLOY_ROOT/windows/stage-isolated-control.ps1" \
    "cape-inetsim-autodeploy-stage" "$stage_result" \
    -IsolatedMac "$isolated_mac" \
    -FakeIP "$fake_ip" \
    -PrefixLength "$prefix" \
    -PinnedClientIP "$CAPE_AGENT_CLIENT_IP" \
    -IsolatedGatewayIP "$BRIDGE_IP" \
    -AgentPort "$CAPE_AGENT_PORT"
  validate_cape_agent_stage_result_path "$stage_result" "$fake_ip" "$isolated_mac" "$CAPE_AGENT_CLIENT_IP" "$BRIDGE_IP" || {
    fail "Windows isolated CAPE Agent staging result did not validate"
    return 1
  }

  cape_agent_wait "$fake_ip" 60 || {
    fail "Pinned CAPE Agent identity $CAPE_AGENT_CLIENT_IP could not reach isolated control path $fake_ip:$CAPE_AGENT_PORT"
    return 1
  }
  pass "Proved pinned CAPE Agent identity over isolated Windows control path"

  # Management hardening now runs synchronously over the stable isolated path.
  # This returns runner stdout/stderr directly if PowerShell fails.
  cape_agent_run_powershell_sync \
    "$fake_ip" "$AUTODEPLOY_ROOT/windows/configure-inetsim.ps1" \
    "cape-inetsim-autodeploy" "$local_result" \
    -ManagementIP "$management_ip" \
    -IsolatedMac "$isolated_mac" \
    -FakeIP "$fake_ip" \
    -PrefixLength "$prefix" \
    -DnsIP "$dns_ip" \
    -ResultServerIP "$result_ip" \
    -ResultServerPort "$result_port" \
    -ControlHostIP "$control_host_ip" \
    -PinnedClientIP "$CAPE_AGENT_CLIENT_IP" \
    -IsolatedGatewayIP "$BRIDGE_IP"
  validate_windows_result_path "$local_result"

  # The pinned-client /32 route is transport scaffolding only. Remove it after
  # the full hardening response has returned so normal CAPE traffic resumes on
  # the management NIC, then prove that management control is healthy again.
  cape_agent_finalize_isolated_control "$fake_ip" "$management_ip"

  WINDOWS_BACKEND_USED=cape-agent-execpy
  state_record_resource windows-config "$DOMAIN" configured-via-cape-agent-execpy yes \
    "isolated_mac=$isolated_mac fake_ip=$fake_ip control_path=management-finalized pinned_client=$CAPE_AGENT_CLIENT_IP agent_version=${CAPE_AGENT_VERSION:-unknown}"
  state_write_atomic
}

windows_verify_via_cape_agent() {
  local management_ip="$1" isolated_mac="$2" fake_ip="$3" dns_ip="$4" result_ip="$5" result_port="$6"
  local local_result="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-windows-verify.json"

  cape_agent_prepare_client_identity "$management_ip" || return 1
  cape_agent_wait "$management_ip" 60 || {
    fail "CAPE Agent is not reachable on the management path after isolated-control finalization"
    return 1
  }

  cape_agent_run_powershell_sync \
    "$management_ip" "$AUTODEPLOY_ROOT/windows/verify-inetsim.ps1" \
    "cape-inetsim-autodeploy-verify" "$local_result" \
    -ManagementIP "$management_ip" \
    -IsolatedMac "$isolated_mac" \
    -FakeIP "$fake_ip" \
    -DnsIP "$dns_ip" \
    -ResultServerIP "$result_ip" \
    -ResultServerPort "$result_port" \
    -PinnedClientIP "$CAPE_AGENT_CLIENT_IP"
  validate_windows_result_path "$local_result"
}

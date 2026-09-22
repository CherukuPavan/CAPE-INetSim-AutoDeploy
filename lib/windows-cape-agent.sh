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
    try:
        data=base64.b64decode(v).decode("utf-8","replace")
    except Exception:
        data=str(v)
    lines.append(f"{k}:\n{data}")
pathlib.Path(dst).write_text("\n".join(lines)+"\n",encoding="utf-8")
PY
}

cape_agent_execpy_sync() {
  local ip="$1" remote_python="$2" json_log="$3"
  local text_log="${json_log%.json}.txt"
  local tmp="${json_log}.tmp.$$" http rc=0
  rm -f "$tmp" "$json_log" "$text_log"

  # Once the isolated path is proven stable, a synchronous execpy request is
  # preferable: CAPE Agent returns the runner's stdout/stderr and exit code
  # directly instead of hiding failures behind async status polling.
  if ! http="$(cape_agent_curl "$ip" -sS --connect-timeout 3 \
      --max-time "$((CAPE_AGENT_GUEST_TIMEOUT + 30))" \
      -o "$tmp" -w '%{http_code}' \
      --data-urlencode "filepath=$remote_python" \
      --data-urlencode "encoding=base64" \
      "$(cape_agent_url "$ip")/execpy")"; then
    rc=$?
    [[ -f "$tmp" ]] && mv -f "$tmp" "$json_log" || : >"$json_log"
    printf 'curl_transport_error=%s\n' "$rc" >"$text_log"
    return 1
  fi
  mv -f "$tmp" "$json_log"
  cape_agent_decode_execpy_log "$json_log" "$text_log"

  [[ "$http" == 200 ]] || return 1
  python3 - "$json_log" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding="utf-8"))
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if int(d.get("status_code",0))==200 else 2)
PY
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
  elif ! cape_agent_execpy_sync "$ip" "$remote_runner" "$exec_log"; then
    exec_rc=53
  fi

  if cape_agent_retrieve "$ip" "$remote_result" "$local_result" 8 >/dev/null 2>&1 && [[ -s "$local_result" ]]; then
    result_ok=yes
  fi
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
    -ControlHostIP "$control_host_ip"
  validate_windows_result_path "$local_result"
  WINDOWS_BACKEND_USED=cape-agent-execpy
  state_record_resource windows-config "$DOMAIN" configured-via-cape-agent-execpy yes \
    "isolated_mac=$isolated_mac fake_ip=$fake_ip control_path=isolated pinned_client=$CAPE_AGENT_CLIENT_IP agent_version=${CAPE_AGENT_VERSION:-unknown}"
  state_write_atomic
}

windows_verify_via_cape_agent() {
  local management_ip="$1" isolated_mac="$2" fake_ip="$3" dns_ip="$4" result_ip="$5" result_port="$6"
  local control_ip=""
  local local_result="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-windows-verify.json"

  cape_agent_prepare_client_identity "$management_ip" || return 1
  if cape_agent_wait "$fake_ip" 30; then
    control_ip="$fake_ip"
  elif cape_agent_wait "$management_ip" 30; then
    control_ip="$management_ip"
  else
    fail "CAPE Agent unavailable on both isolated and management paths for Windows safety verification"
    return 1
  fi

  cape_agent_run_powershell_sync \
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

#!/usr/bin/env bash

# CAPE rooter discovery/readiness validation.

discover_rooter_socket() {
  CAPE_ROOTER_SOCKET=""
  [[ -n "${CAPE_ROOT:-}" ]] || return 0
  local py="${CAPE_PYTHON:-${AD_HOST_PYTHON:-}}" sock
  if [[ -x "$py" && -f "$CAPE_ROOT/conf/cuckoo.conf" ]]; then
    sock="$("$py" - "$CAPE_ROOT/conf/cuckoo.conf" <<'PY' 2>/dev/null || true
import configparser,sys
c=configparser.ConfigParser(interpolation=None, strict=False)
c.read(sys.argv[1])
print(c.get("cuckoo","rooter",fallback=c.get("rooter","socket",fallback="")))
PY
)"
    [[ -n "$sock" ]] && CAPE_ROOTER_SOCKET="$sock"
  fi
  if [[ -z "$CAPE_ROOTER_SOCKET" && -f "$CAPE_ROOT/conf/cuckoo.conf" ]]; then
    CAPE_ROOTER_SOCKET="$(awk -F= '/^[[:space:]]*rooter[[:space:]]*=/{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2);print $2;exit}' "$CAPE_ROOT/conf/cuckoo.conf")"
  fi
  if [[ -z "$CAPE_ROOTER_SOCKET" && -n "${CAPE_ROOTER_SERVICE:-}" ]]; then
    local exec
    exec="$(service_execstart_text "$CAPE_ROOTER_SERVICE")"
    CAPE_ROOTER_EXECUTABLE="$(awk '{for(i=1;i<=NF;i++) if($i ~ /rooter\.py$/){print $i;exit}}' <<<"$exec")"
  fi
  export CAPE_ROOTER_SOCKET CAPE_ROOTER_EXECUTABLE
}

rooter_start_and_wait() {
  [[ -n "${CAPE_ROOTER_SERVICE:-}" ]] || { fail "CAPE rooter service was not discovered"; return 1; }
  systemctl is-active --quiet "$CAPE_ROOTER_SERVICE" || systemctl start "$CAPE_ROOTER_SERVICE"
  local i
  for ((i=0;i<30;i++)); do
    if [[ -n "${CAPE_ROOTER_SOCKET:-}" && -S "$CAPE_ROOTER_SOCKET" ]]; then return 0; fi
    sleep 1
  done
  fail "CAPE rooter socket did not become ready: ${CAPE_ROOTER_SOCKET:-unknown}"
  return 1
}

rooter_structured_probe() {
  [[ -x "${CAPE_PYTHON:-}" ]] || { fail "CAPE Python is unavailable for rooter probe"; return 1; }
  (cd "$CAPE_ROOT" && "$CAPE_PYTHON" - <<'PY'
import json
from lib.cuckoo.core.rooter import rooter
reply = rooter("nic_available", "lo")
if not isinstance(reply, dict):
    raise SystemExit("rooter reply is not structured")
if reply.get("exception"):
    raise SystemExit("rooter exception: %s" % reply["exception"])
if "output" not in reply:
    raise SystemExit("rooter reply has no output field")
print(json.dumps(reply, sort_keys=True))
PY
  ) >"$AD_LOG_ROOT/${DEPLOYMENT_ID:-discovery}-rooter-probe.json"
}

validate_rooter_ready() {
  discover_rooter_socket
  rooter_start_and_wait
  rooter_structured_probe
  pass "CAPE rooter service/socket/structured command probe passed"
}

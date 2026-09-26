#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
SERVER_PID=""
trap '[[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/services.sh"
source "$ROOT/lib/validate.sh"

# Service readiness must distinguish "not active yet" from a terminal failure.
systemctl() {
  case "$1" in
    is-active)
      if [[ "${2:-}" == "--quiet" ]]; then return 0; fi
      printf 'active\n'
      return 0
      ;;
    is-failed) return 1 ;;
    *) return 0 ;;
  esac
}
CAPE_SERVICE_READY_TIMEOUT=3
CAPE_SERVICE_READY_POLL=1
services_wait_expected_active cape.service 3

systemctl() {
  case "$1" in
    is-active)
      if [[ "${2:-}" == "--quiet" ]]; then return 1; fi
      printf 'failed\n'
      return 3
      ;;
    is-failed) return 0 ;;
    *) return 0 ;;
  esac
}
if services_wait_expected_active cape.service 3 >/dev/null 2>&1; then
  echo "service readiness accepted a failed cape.service" >&2
  exit 1
fi

# RC31 regression: systemd can report cape.service active before CAPE's
# ResultServer socket is listening. Bind the endpoint now, delay listen(), and
# prove validation retries until the socket is genuinely ready.
PORT_FILE="$TMP/port"
python3 - "$PORT_FILE" <<'PY' &
import socket,sys,time
p=sys.argv[1]
s=socket.socket()
s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",0))
open(p,"w").write(str(s.getsockname()[1]))
time.sleep(1.25)
s.listen(4)
conn,_=s.accept()
conn.close()
s.close()
PY
SERVER_PID=$!
for _ in {1..50}; do [[ -s "$PORT_FILE" ]] && break; sleep 0.02; done
[[ -s "$PORT_FILE" ]]

systemctl() {
  case "$1" in
    is-active)
      if [[ "${2:-}" == "--quiet" ]]; then return 0; fi
      printf 'active\n'
      return 0
      ;;
    is-failed) return 1 ;;
    *) return 0 ;;
  esac
}

AD_LOG_ROOT="$TMP"
DEPLOYMENT_ID="rc31-readiness-regression"
CAPE_SERVICE_WAS_ACTIVE=yes
CAPE_MACHINE_SECTION=win10
CAPE_RESULTSERVER_IP=127.0.0.1
CAPE_RESULTSERVER_PORT="$(cat "$PORT_FILE")"
CAPE_RESULTSERVER_READY_TIMEOUT=6
CAPE_RESULTSERVER_READY_POLL=1

validate_resultserver_host
wait "$SERVER_PID"
SERVER_PID=""

LOG="$TMP/${DEPLOYMENT_ID}-cape-resultserver-readiness.log"
grep -Fq 'status=waiting' "$LOG"
grep -Fq 'status=ready' "$LOG"
[[ "$(grep -Fc 'status=waiting' "$LOG")" -ge 1 ]]

# Static guards for the production path.
grep -Fq 'CAPE_RESULTSERVER_READY_TIMEOUT:-90' "$ROOT/lib/validate.sh"
grep -Fq 'systemctl is-failed --quiet cape.service' "$ROOT/lib/validate.sh"
grep -Fq 'Timed out waiting ${ready_timeout}s for CAPE ResultServer readiness' "$ROOT/lib/validate.sh"
grep -Fq 'services_wait_expected_active' "$ROOT/lib/services.sh"

# A service being systemd-active is not enough. If ResultServer never opens,
# the bounded readiness gate must fail instead of accepting the handoff.
CAPE_MACHINE_SECTION=win7
CAPE_RESULTSERVER_IP=127.0.0.1
CAPE_RESULTSERVER_PORT=9
CAPE_RESULTSERVER_READY_TIMEOUT=2
CAPE_RESULTSERVER_READY_POLL=1
if validate_resultserver_host >/dev/null 2>&1; then
  echo "ResultServer readiness accepted an active service with a closed endpoint" >&2
  exit 1
fi

grep -Fq 'services_wait_expected_active' "$ROOT/lib/services.sh"
grep -Fq 'CAPE_SERVICE_READY_TIMEOUT' "$ROOT/lib/services.sh"

# RC62 routing prerequisite lifecycle: prove the project-owned sysctl is
# applied, verified and restored without touching the CI runner's real sysctls.
ROUTING_SYSCTL_FILE="$TMP/route-forwarding.conf"
HOST_IPV4_FORWARD_WAS=""
FORWARD_VALUE=0
declare -A OWNED=()

sysctl() {
  if [[ "$1" == -n && "$2" == net.ipv4.ip_forward ]]; then
    printf '%s\n' "$FORWARD_VALUE"
    return 0
  fi
  if [[ "$1" == -w && "$2" == net.ipv4.ip_forward=* ]]; then
    FORWARD_VALUE="${2#*=}"
    printf 'net.ipv4.ip_forward = %s\n' "$FORWARD_VALUE"
    return 0
  fi
  return 1
}
state_write_atomic(){ :; }
state_resource_intended(){ return 1; }
state_record_intent(){ :; }
state_resource_owned(){
  [[ "${OWNED[$1:$2]:-no}" == yes ]]
}
state_record_resource(){
  local key="$1:$2" action="$3"
  case "$action" in
    created|enabled) OWNED["$key"]=yes ;;
    removed*|restored*) OWNED["$key"]=no ;;
  esac
}

routing_forwarding_apply
[[ "$FORWARD_VALUE" == 1 ]]
[[ "$HOST_IPV4_FORWARD_WAS" == 0 ]]
routing_forwarding_verify
grep -Fq 'net.ipv4.ip_forward = 1' "$ROUTING_SYSCTL_FILE"
routing_forwarding_rollback
[[ "$FORWARD_VALUE" == 0 ]]
[[ ! -e "$ROUTING_SYSCTL_FILE" ]]

grep -Fq 'services_prepare_route_control_plane' "$ROOT/lib/deploy.sh"
grep -Fq 'services_activate_deployment_state' "$ROOT/lib/deploy.sh"
grep -Fq 'routing_forwarding_apply' "$ROOT/bin/cape-inetsim-repair"
grep -Fq 'systemctl enable cape-rooter.service' "$ROOT/bin/cape-inetsim-repair"
grep -Fq 'routing_forwarding_rollback' "$ROOT/lib/rollback.sh"
grep -Fq 'cape_probe_inetsim_rooter_all' "$ROOT/lib/validate.sh"

echo '[PASS] route=inetsim owns IPv4 forwarding and requires persistent CAPE Rooter readiness'

echo '[PASS] final CAPE handoff waits for real service/ResultServer readiness'

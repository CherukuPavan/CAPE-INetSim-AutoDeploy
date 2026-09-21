#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/targets.sh"
source "$ROOT/lib/rollback.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/rollback.log"

CAPE_TARGETS_JSON='[
 {"section":"win10","domain":"vm-a","safety_snapshot":"pre-a","isolated_mac":"52:54:00:aa:00:01","phase":"cape-configured"},
 {"section":"win11","domain":"vm-b","safety_snapshot":"pre-b","isolated_mac":"52:54:00:aa:00:02","phase":"cape-configured"},
 {"section":"win7","domain":"vm-c","safety_snapshot":"pre-c","isolated_mac":"52:54:00:aa:00:03","phase":"cape-configured"}
]'
CAPE_TARGETS_COUNT=3
TARGET_INDEX=0
targets_bind 0

ROLLBACK_FAILURES=0
ROLLBACK_CRITICAL_FAILURES=0
AD_STATE_FILE="$TMP/state.env"

state_has_owned_kind(){
  case "$1" in
    windows-config|domain-interface|snapshot|domain-interface-filter) return 0 ;;
    *) return 1 ;;
  esac
}
state_write_atomic(){ :; }
windows_rollback_to_safety(){ echo "$CAPE_MACHINE_SECTION:$DOMAIN:$SAFETY_SNAPSHOT" >>"$LOG"; }
services_stop_scheduler_for_handoff(){ echo scheduler-stop >>"$LOG"; }
systemctl(){
  if [[ "$1" == is-active ]]; then return 0; fi
  return 0
}
extension_rollback(){ :; }
cape_restore_integration_files(){ :; }

rollback_restore_cutover

mapfile -t rows < <(grep -v '^scheduler-stop$' "$LOG")
[[ "${#rows[@]}" -eq 3 ]]
[[ "${rows[0]}" == 'win7:vm-c:pre-c' ]]
[[ "${rows[1]}" == 'win11:vm-b:pre-b' ]]
[[ "${rows[2]}" == 'win10:vm-a:pre-a' ]]
grep -Fxq scheduler-stop "$LOG"

echo '[PASS] rollback restores every CAPE analysis VM in reverse transactional order'

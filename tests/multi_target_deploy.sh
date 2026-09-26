#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/targets.sh"
source "$ROOT/lib/deploy.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/actions.log"

# No real host/VM operation is performed in this unit test.
DEPLOYMENT_ID=test
DEPLOYMENT_PHASE=maintenance-acquired
CAPE_TARGETS_JSON='[
 {"section":"cape1","label":"cape1","ip":"192.0.2.10","domain":"vm-a","fake_ip":"198.51.100.10","phase":"discovered"},
 {"section":"win10","label":"win10","ip":"192.0.2.11","domain":"vm-b","fake_ip":"198.51.100.11","phase":"discovered"},
 {"section":"win7","label":"win7","ip":"192.0.2.12","domain":"vm-c","fake_ip":"198.51.100.12","phase":"discovered"}
]'
CAPE_TARGETS_COUNT=3

state_write_atomic(){ :; }
state_set_phase(){ DEPLOYMENT_PHASE="$1"; }
deploy_ensure_maintenance(){ :; }
windows_stop_for_cutover(){ echo "stop:$DOMAIN" >>"$LOG"; WINDOWS_ORIGINAL_DOMAIN_STATE="shut off"; }
windows_create_safety_snapshot(){ SAFETY_SNAPSHOT="pre-$DOMAIN"; echo "safety:$DOMAIN" >>"$LOG"; }
windows_management_dhcp_align_if_needed(){ echo "dhcp:$DOMAIN" >>"$LOG"; }
windows_configured_snapshot_is_running_baseline(){ return 0; }
windows_restore_configured_snapshot_paused(){ echo "restore:$DOMAIN" >>"$LOG"; }
windows_management_guard_apply(){ echo "guard:$DOMAIN" >>"$LOG"; }
windows_attach_isolated_nic(){ WINDOWS_ISOLATED_MAC="52:54:00:aa:00:$(printf '%02d' $((TARGET_INDEX+1)))"; echo "nic:$DOMAIN" >>"$LOG"; }
firewall_enable_windows_management_guard(){ echo "firewall:$DOMAIN" >>"$LOG"; }
windows_start_for_cutover(){ echo "start:$DOMAIN" >>"$LOG"; }
windows_select_live_backend(){ WINDOWS_BACKEND_USED=cape-agent-execpy; echo "backend:$DOMAIN" >>"$LOG"; }
windows_configure_selected_backend(){ echo "configure:$DOMAIN:$WINDOWS_FAKE_IP" >>"$LOG"; }
windows_verify_selected_backend(){ echo "verify:$DOMAIN" >>"$LOG"; }
deploy_finish_windows_snapshots(){
  WORKING_SNAPSHOT="working-$DOMAIN"
  FINAL_SNAPSHOT="ready-$DOMAIN"
  echo "snapshots:$DOMAIN" >>"$LOG"
  target_state_set_phase snapshots-ready
}

deploy_windows_cutover

[[ "$DEPLOYMENT_PHASE" == windows-all-ready ]]
for i in 0 1 2; do
  [[ "$(targets_get "$i" phase)" == snapshots-ready ]]
  [[ -n "$(targets_get "$i" safety_snapshot)" ]]
  [[ -n "$(targets_get "$i" final_snapshot)" ]]
  [[ -n "$(targets_get "$i" isolated_mac)" ]]
done

for d in vm-a vm-b vm-c; do
  grep -Fxq "stop:$d" "$LOG"
  grep -Fxq "safety:$d" "$LOG"
  grep -Fxq "dhcp:$d" "$LOG"
  grep -Fxq "restore:$d" "$LOG"
  grep -Fxq "guard:$d" "$LOG"
  grep -Fxq "nic:$d" "$LOG"
  grep -Fxq "firewall:$d" "$LOG"
  grep -Fxq "start:$d" "$LOG"
  grep -Fxq "backend:$d" "$LOG"
  grep -Fxq "verify:$d" "$LOG"
  grep -Fxq "snapshots:$d" "$LOG"
done

python3 - "$LOG" <<'PY'
import sys
lines=open(sys.argv[1],encoding="utf-8").read().splitlines()
for domain in ("vm-a","vm-b","vm-c"):
    pos={name:lines.index(f"{name}:{domain}") for name in ("stop","safety","dhcp","restore","guard","nic","firewall","start","backend","verify","snapshots")}
    assert pos["stop"] < pos["safety"] < pos["dhcp"] < pos["restore"] < pos["guard"] < pos["nic"] < pos["firewall"] < pos["start"] < pos["backend"]
PY

[[ "$(grep -c '^configure:' "$LOG")" -eq 3 ]]
grep -Fxq 'configure:vm-a:198.51.100.10' "$LOG"
grep -Fxq 'configure:vm-b:198.51.100.11' "$LOG"
grep -Fxq 'configure:vm-c:198.51.100.12' "$LOG"

echo '[PASS] transactional Windows cutover iterates and persists every CAPE analysis VM'

# SSL-44 regression: after successful live configuration/verification, final
# running snapshot must be captured BEFORE the single shutdown used for the
# configured rollback snapshot. A second boot/backend probe is forbidden.
# Restore the real implementation after the multi-target harness stub above.
source "$ROOT/lib/deploy.sh"
SNAPLOG="$TMP/snapshot-order.log"
: >"$SNAPLOG"
DOMAIN=ssl44-win10
CAPE_MACHINE_SECTION=win10
TARGET_PHASE=configured
FINAL_SNAPSHOT=""
WORKING_SNAPSHOT=""
VM_STATE=running

windows_snapshot_exists(){ return 1; }
virsh(){
  case "$1" in
    domstate) echo "$VM_STATE" ;;
    *) return 0 ;;
  esac
}
windows_create_running_snapshot(){
  [[ "$VM_STATE" == running ]]
  FINAL_SNAPSHOT=ready-ssl44
  echo final >>"$SNAPLOG"
}
windows_poweroff_selected_backend(){
  echo poweroff >>"$SNAPLOG"
  VM_STATE="shut off"
}
windows_create_working_snapshot(){
  [[ "$VM_STATE" == "shut off" ]]
  WORKING_SNAPSHOT=working-ssl44
  echo working >>"$SNAPLOG"
}
snapshot_state_memory(){
  case "$1" in
    working-ssl44) echo 'shutoff|no' ;;
    ready-ssl44) echo 'running|internal' ;;
    *) return 1 ;;
  esac
}
snapshot_is_running_analysis_baseline(){
  [[ "$1" == ready-ssl44 ]]
}
target_state_set_phase(){ TARGET_PHASE="$1"; }

windows_start_for_cutover(){ echo unexpected-start >>"$SNAPLOG"; return 91; }
windows_select_live_backend(){ echo unexpected-backend >>"$SNAPLOG"; return 92; }
windows_verify_selected_backend(){ echo unexpected-verify >>"$SNAPLOG"; return 93; }

deploy_finish_windows_snapshots

mapfile -t SNAP_EVENTS <"$SNAPLOG"
[[ "${SNAP_EVENTS[*]}" == "final poweroff working" ]]
[[ "$TARGET_PHASE" == snapshots-ready ]]
[[ "$VM_STATE" == "shut off" ]]
! grep -Fq 'unexpected-' "$SNAPLOG"

echo '[PASS] final CAPE running snapshot is preserved before one-shot shutdown; no second control bootstrap'

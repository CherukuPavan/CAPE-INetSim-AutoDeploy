#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/targets.sh"
source "$ROOT/lib/deploy.sh"

# Route-scoped INetSim must not rewrite Windows networking, attach a fake NIC,
# manufacture a replacement snapshot, or bootstrap a guest-control backend.
DEPLOYMENT_ID=test
DEPLOYMENT_PHASE=maintenance-acquired
CAPE_TARGETS_JSON='[
 {"section":"cape1","label":"cape1","ip":"192.0.2.10","domain":"vm-a","original_snapshot":"snap-a","analysis_snapshot_status":"proven","analysis_snapshot_state":"running","analysis_snapshot_memory":"internal","phase":"discovered"},
 {"section":"win10","label":"win10","ip":"192.0.2.11","domain":"vm-b","original_snapshot":"snap-b","analysis_snapshot_status":"proven","analysis_snapshot_state":"running","analysis_snapshot_memory":"external","phase":"discovered"},
 {"section":"win7","label":"win7","ip":"192.0.2.12","domain":"vm-c","original_snapshot":"snap-c","analysis_snapshot_status":"proven","analysis_snapshot_state":"running","analysis_snapshot_memory":"internal","phase":"discovered"}
]'
CAPE_TARGETS_COUNT=3

state_write_atomic(){ :; }
state_set_phase(){ DEPLOYMENT_PHASE="$1"; }
deploy_ensure_maintenance(){ :; }
windows_configured_snapshot_is_running_baseline(){ return 0; }

# Every legacy mutation path is forbidden in the route-scoped design.
windows_stop_for_cutover(){ echo unexpected-stop >&2; return 91; }
windows_create_safety_snapshot(){ echo unexpected-safety >&2; return 92; }
windows_management_dhcp_align_if_needed(){ echo unexpected-dhcp >&2; return 93; }
windows_restore_configured_snapshot_paused(){ echo unexpected-restore >&2; return 94; }
windows_management_guard_apply(){ echo unexpected-guard >&2; return 95; }
windows_attach_isolated_nic(){ echo unexpected-nic >&2; return 96; }
firewall_enable_windows_management_guard(){ echo unexpected-firewall >&2; return 97; }
windows_start_for_cutover(){ echo unexpected-start >&2; return 98; }
windows_select_live_backend(){ echo unexpected-backend >&2; return 99; }
windows_configure_selected_backend(){ echo unexpected-configure >&2; return 100; }
windows_verify_selected_backend(){ echo unexpected-verify >&2; return 101; }

deploy_windows_cutover

[[ "$DEPLOYMENT_PHASE" == windows-all-ready ]]

for i in 0 1 2; do
  original="$(targets_get "$i" original_snapshot)"
  [[ "$(targets_get "$i" phase)" == snapshots-ready ]]
  [[ "$(targets_get "$i" final_snapshot)" == "$original" ]]
  [[ -z "$(targets_get "$i" safety_snapshot)" ]]
  [[ -z "$(targets_get "$i" working_snapshot)" ]]
  [[ -z "$(targets_get "$i" isolated_mac)" ]]
  [[ "$(targets_get "$i" backend_used)" == cape-native-route ]]
done

echo '[PASS] route-scoped cutover preserves every CAPE Windows baseline without guest-network mutation'

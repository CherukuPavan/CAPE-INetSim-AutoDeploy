#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/targets.sh"
source "$ROOT/lib/deploy.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

DEPLOYMENT_ID=test
DEPLOYMENT_PHASE=maintenance-acquired
CAPE_TARGETS_JSON='[
 {"section":"cape1","label":"cape1","ip":"192.0.2.10","domain":"vm-a","original_snapshot":"snap-a","phase":"discovered"},
 {"section":"win10","label":"win10","ip":"192.0.2.11","domain":"vm-b","original_snapshot":"snap-b","phase":"discovered"},
 {"section":"win7","label":"win7","ip":"192.0.2.12","domain":"vm-c","original_snapshot":"snap-c","phase":"discovered"}
]'
CAPE_TARGETS_COUNT=3

state_write_atomic(){ :; }
state_set_phase(){ DEPLOYMENT_PHASE="$1"; }
deploy_ensure_maintenance(){ :; }
virsh(){
  [[ "$1" == snapshot-info ]] && return 0
  return 0
}

# Route-separated deployment must not touch guest networking, NICs or snapshots.
windows_stop_for_cutover(){ echo "unexpected windows_stop_for_cutover" >&2; return 91; }
windows_create_safety_snapshot(){ echo "unexpected windows_create_safety_snapshot" >&2; return 92; }
windows_attach_isolated_nic(){ echo "unexpected windows_attach_isolated_nic" >&2; return 93; }
windows_configure_selected_backend(){ echo "unexpected windows_configure_selected_backend" >&2; return 94; }
windows_create_running_snapshot(){ echo "unexpected windows_create_running_snapshot" >&2; return 95; }

deploy_windows_cutover

[[ "$DEPLOYMENT_PHASE" == windows-all-ready ]]
expected=(snap-a snap-b snap-c)
for i in 0 1 2; do
  [[ "$(targets_get "$i" phase)" == snapshots-ready ]]
  [[ "$(targets_get "$i" final_snapshot)" == "${expected[$i]}" ]]
  [[ -z "$(targets_get "$i" safety_snapshot)" ]]
  [[ -z "$(targets_get "$i" working_snapshot)" ]]
  [[ -z "$(targets_get "$i" isolated_mac)" ]]
done

echo '[PASS] route-separated deployment preserves every CAPE analysis VM unchanged'

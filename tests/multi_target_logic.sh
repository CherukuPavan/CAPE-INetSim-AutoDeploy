#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/cape.sh"
source "$ROOT/lib/targets.sh"

# Default discovery must enumerate every enabled Windows-compatible CAPE
# analysis record instead of trying to pick one "best" machine.
CAPE_MACHINE_RECORDS=(
  '{"section":"cape1","label":"cape1","ip":"192.0.2.10","snapshot":"","interface":"","platform":"windows"}'
  '{"section":"win10","label":"win10","ip":"192.0.2.11","snapshot":"snap10","interface":"","platform":"windows"}'
  '{"section":"win7","label":"win7","ip":"192.0.2.12","snapshot":"","interface":"","platform":"windows"}'
)
REQUESTED_MACHINE=""
DISCOVERY_ERRORS=()

match_selected_domain(){ DOMAIN="$CAPE_MACHINE_SECTION"; DOMAIN_XML="<domain/>"; }
discover_domain_details(){ DOMAIN_STATE="shut off"; DOMAIN_NIC_COUNT=1; DOMAIN_NIC_MODELS=e1000e; }
discover_windows_snapshot_capability(){ WINDOWS_INTERNAL_SNAPSHOT_CAPABLE=yes; }
discover_management_network(){ MANAGEMENT_NETWORK_NAME=default; }
discover_management_network_details(){ MANAGEMENT_BRIDGE_NAME=virbr0; WINDOWS_MANAGEMENT_MAC="52:54:00:00:00:$(printf '%02x' $((10 + ${#CAPE_MACHINE_SECTION})))"; }
discover_resultserver(){ CAPE_RESULTSERVER_IP=192.0.2.1; CAPE_RESULTSERVER_PORT=2042; CONTROL_HOST_IP=192.0.2.1; }
discover_cape_analysis_snapshot(){
  if [[ -n "${CAPE_MACHINE_SNAPSHOT:-}" ]]; then
    CAPE_ANALYSIS_SNAPSHOT_STATUS=proven
    CAPE_ANALYSIS_SNAPSHOT_STATE=running
    CAPE_ANALYSIS_SNAPSHOT_MEMORY=internal
  else
    CAPE_ANALYSIS_SNAPSHOT_STATUS=not-configured
    CAPE_ANALYSIS_SNAPSHOT_STATE=""
    CAPE_ANALYSIS_SNAPSHOT_MEMORY=""
  fi
}
discover_windows_backends(){ QGA_AVAILABLE=no; WINRM_AVAILABLE=no; CAPE_AGENT_REACHABLE=yes; WINDOWS_BACKEND=cape-agent-execpy-candidate; }

targets_discover_all
[[ "$(targets_count)" -eq 3 ]]
[[ "${#DISCOVERY_ERRORS[@]}" -eq 0 ]]

ISOLATED_SUBNET=192.168.200.0/24
targets_prepare_after_network_plan
[[ -z "$(targets_get 0 fake_ip)" ]]
[[ -z "$(targets_get 1 fake_ip)" ]]
[[ -z "$(targets_get 2 fake_ip)" ]]

targets_bind 1
[[ "$CAPE_MACHINE_SECTION" == win10 ]]
[[ "$DOMAIN" == win10 ]]
[[ -z "$WINDOWS_FAKE_IP" ]]

identity_before="$(targets_identity_sha256)"
WINDOWS_ISOLATED_MAC=52:54:00:aa:bb:cc
WINDOWS_BACKEND_USED=cape-agent-execpy
SAFETY_SNAPSHOT=pre
WORKING_SNAPSHOT=working
FINAL_SNAPSHOT=ready
TARGET_PHASE=snapshots-ready
targets_capture_bound 1
[[ "$(targets_get 1 isolated_mac)" == 52:54:00:aa:bb:cc ]]
[[ "$(targets_get 1 final_snapshot)" == ready ]]
[[ "$(targets_get 1 phase)" == snapshots-ready ]]
[[ "$(targets_identity_sha256)" == "$identity_before" ]]

summary="$(targets_summary_lines)"
grep -Fq 'win10 -> win10' <<<"$summary"
grep -Fq 'snapshot=ready' <<<"$summary"
! grep -Fq 'snapshot=snap10' <<<"$summary"

# --machine remains a deliberate single-target override, but the default is all.
REQUESTED_MACHINE=win7
DISCOVERY_ERRORS=()
targets_discover_all
[[ "$(targets_count)" -eq 1 ]]
[[ "$(targets_get 0 section)" == win7 ]]

# Duplicate runtime identities must block rather than silently choose.
CAPE_TARGETS_JSON='[
  {"section":"a","label":"a","ip":"192.0.2.10","domain":"same"},
  {"section":"b","label":"b","ip":"192.0.2.11","domain":"same"}
]'
DISCOVERY_ERRORS=()
targets_validate_uniqueness
[[ "${#DISCOVERY_ERRORS[@]}" -eq 1 ]]
grep -Fq 'libvirt domain is not unique' <<<"${DISCOVERY_ERRORS[0]}"

# Static policy: production discovery/deployment/CAPE integration are target-set
# oriented; route-scoped deployment preserves already-proven CAPE snapshots.
grep -Fq 'targets_discover_all' "$ROOT/lib/plan.sh"
! grep -Fq 'auto_select_cape_machine' "$ROOT/lib/plan.sh"
grep -Fq 'for ((i=0;i<CAPE_TARGETS_COUNT;i++))' "$ROOT/lib/deploy.sh"
grep -Fq 'for ((i=0;i<CAPE_TARGETS_COUNT;i++))' "$ROOT/lib/cape-configure.sh"
grep -Fq 'CAPE_ANALYSIS_SNAPSHOT_STATUS="not-configured"' "$ROOT/lib/libvirt.sh"
grep -Fq 'analysis_snapshot_status") == "proven"' "$ROOT/lib/deploy.sh"
grep -Fq 'No supported zero-touch Windows control channel is available' "$ROOT/lib/windows-control.sh"
grep -Fq 'CAPE_DOMAIN=' "$ROOT/lib/extension.sh"

echo '[PASS] all enabled CAPE Windows analysis VMs are modeled as one transactional target set'

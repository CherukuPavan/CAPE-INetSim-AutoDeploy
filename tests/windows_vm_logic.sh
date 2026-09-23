#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/windows-vm.sh"
DOMAIN=testvm
ISOLATED_NETWORK_NAME=cape-inetsim-isolated

virsh() {
  case "$1" in
    dumpxml)
      cat <<'XML'
<domain><devices>
  <interface type='network'><mac address='52:54:00:11:22:33'/><source network='default'/><model type='e1000e'/></interface>
  <interface type='network'><mac address='52:54:00:aa:bb:cc'/><source network='cape-inetsim-isolated'/><model type='e1000e'/></interface>
  <video><model type='qxl'/></video>
</devices></domain>
XML
      ;;
    snapshot-dumpxml)
      if [[ "${3:-}" == ready-external ]]; then
        cat <<'XML'
<domainsnapshot><name>ready-external</name><state>running</state><memory snapshot='external' file='/tmp/ready.mem'/></domainsnapshot>
XML
      else
        cat <<'XML'
<domainsnapshot><name>ready</name><state>running</state><memory snapshot='internal'/></domainsnapshot>
XML
      fi
      ;;
    *) return 1 ;;
  esac
}

records="$(windows_existing_network_interfaces "$DOMAIN")"
grep -q '^default||52:54:00:11:22:33|e1000e$' <<<"$records"
grep -q '^cape-inetsim-isolated||52:54:00:aa:bb:cc|e1000e$' <<<"$records"
windows_choose_nic_model
[[ "$WINDOWS_ISOLATED_NIC_MODEL" == e1000e ]]
[[ "$(windows_find_isolated_mac)" == '52:54:00:aa:bb:cc' ]]
[[ "$(snapshot_state_memory ready)" == 'running|internal' ]]
[[ "$(snapshot_state_memory ready-external)" == 'running|external' ]]
snapshot_is_running_analysis_baseline ready
snapshot_is_running_analysis_baseline ready-external

echo '[PASS] Windows NIC and internal/external running-snapshot discovery logic'

python3 - "$ROOT/lib/windows-vm.sh" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()
start=s.index("windows_rollback_to_safety()")
body=s[start:]
assert 'intentionally left the analysis VM shut off for network safety' in body
assert 'virsh start "$DOMAIN"' not in body
stop=s[s.index("windows_stop_for_cutover()"):s.index("windows_snapshot_has_child()",s.index("windows_stop_for_cutover()"))]
assert 'qga_wait "$DOMAIN" 5' in stop
assert 'windows_winrm_ready "$CAPE_MACHINE_IP"' in stop
assert 'cape_agent_wait "$CAPE_MACHINE_IP" 15' in stop
assert 'windows_poweroff_via_cape_agent "$CAPE_MACHINE_IP"' in stop
assert 'virsh shutdown "$DOMAIN"' in stop
assert 'refusing forced cutover' in stop
PY


# Regression: reverting the safety snapshot can remove the isolated NIC before
# explicit detach. Rollback must still close domain-interface and windows-config
# ownership so recovery does not falsely remain dirty.
TMP_ROLLBACK="$(mktemp -d)"
SAFETY_SNAPSHOT=pre-change
WINDOWS_ISOLATED_MAC=52:54:00:de:ad:01
WINDOWS_ORIGINAL_DOMAIN_STATE="shut off"
: >"$TMP_ROLLBACK/records"

state_resource_owned() {
  case "$1|$2" in
    "snapshot|$DOMAIN:$SAFETY_SNAPSHOT"|"domain-interface|$DOMAIN:$WINDOWS_ISOLATED_MAC"|"windows-config|$DOMAIN") return 0 ;;
    *) return 1 ;;
  esac
}
windows_snapshot_exists(){ return 0; }
windows_isolated_mac_present(){ return 1; }
windows_delete_owned_snapshots_leaf_first(){ :; }
state_record_resource(){ printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >>"$TMP_ROLLBACK/records"; }
virsh() {
  case "$1" in
    domstate) echo "shut off" ;;
    snapshot-revert) return 0 ;;
    *) return 0 ;;
  esac
}
windows_rollback_to_safety
grep -Fq "domain-interface|$DOMAIN:$WINDOWS_ISOLATED_MAC|removed-by-safety-snapshot|yes" "$TMP_ROLLBACK/records"
grep -Fq "windows-config|$DOMAIN|restored-by-safety-snapshot|yes" "$TMP_ROLLBACK/records"
rm -rf "$TMP_ROLLBACK"

echo '[PASS] safety-snapshot rollback reconciles Windows config/interface ownership'

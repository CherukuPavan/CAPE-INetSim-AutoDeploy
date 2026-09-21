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
      cat <<'XML'
<domainsnapshot><name>ready</name><state>running</state><memory snapshot='internal'/></domainsnapshot>
XML
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

echo '[PASS] Windows NIC and running-snapshot discovery logic'

python3 - "$ROOT/lib/windows-vm.sh" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()
start=s.index("windows_rollback_to_safety()")
body=s[start:]
assert 'intentionally left the analysis VM shut off for network safety' in body
assert 'virsh start "$DOMAIN"' not in body
PY

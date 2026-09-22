#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/windows-vm.sh"
source "$ROOT/lib/validate.sh"

DOMAIN=testvm
FINAL_SNAPSHOT=ready
ISOLATED_NETWORK_NAME=cape-inetsim-isolated
WINDOWS_ISOLATED_MAC=52:54:00:aa:bb:cc
MANAGEMENT_NETWORK_NAME=default
WINDOWS_MANAGEMENT_MAC=52:54:00:11:22:33
WINDOWS_MGMT_FILTER_NAME=clean-traffic
CAPE_MACHINE_IP=192.0.2.10
SNAP_MEMORY=internal
SNAP_STATE=running

virsh() {
  [[ "$1" == snapshot-dumpxml ]] || return 1
  cat <<XML
<domainsnapshot>
  <name>ready</name>
  <state>$SNAP_STATE</state>
  <memory snapshot='$SNAP_MEMORY' file='/tmp/ready.mem'/>
  <domain>
    <name>testvm</name>
    <devices>
      <interface type='network'>
        <mac address='52:54:00:11:22:33'/>
        <source network='default'/>
        <filterref filter='clean-traffic'><parameter name='IP' value='192.0.2.10'/></filterref>
      </interface>
      <interface type='network'>
        <mac address='52:54:00:aa:bb:cc'/>
        <source network='cape-inetsim-isolated'/>
      </interface>
    </devices>
  </domain>
</domainsnapshot>
XML
}

SNAP_MEMORY=internal
SNAP_STATE=running
snapshot_is_running_analysis_baseline "$FINAL_SNAPSHOT"
validate_final_snapshot_hardware

SNAP_MEMORY=external
SNAP_STATE=running
snapshot_is_running_analysis_baseline "$FINAL_SNAPSHOT"
validate_final_snapshot_hardware

SNAP_MEMORY=no
SNAP_STATE=running
! snapshot_is_running_analysis_baseline "$FINAL_SNAPSHOT"
! validate_final_snapshot_hardware

SNAP_MEMORY=external
SNAP_STATE=shutoff
! snapshot_is_running_analysis_baseline "$FINAL_SNAPSHOT"
! validate_final_snapshot_hardware

grep -Fq 'snapshot_is_running_analysis_baseline "$FINAL_SNAPSHOT"' "$ROOT/lib/deploy.sh"
grep -Fq 'memory not in ("internal","external")' "$ROOT/lib/validate.sh"

echo '[PASS] CAPE running analysis snapshots accept internal or external saved memory and reject unsafe states'

#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/inetsim-vm.sh"
xml='<domain type="kvm"><name>x</name><devices><disk type="file" device="disk"/></devices></domain>'
out="$(inject_qga_channel <<<"$xml")"
grep -q 'org.qemu.guest_agent.0' <<<"$out"
[[ "$(grep -o 'org.qemu.guest_agent.0' <<<"$out" | wc -l)" -eq 1 ]]
out2="$(inject_qga_channel <<<"$out")"
[[ "$(grep -o 'org.qemu.guest_agent.0' <<<"$out2" | wc -l)" -eq 1 ]]
source "$ROOT/lib/deploy.sh"
INETSIM_DOMAIN_NAME=temporary-wrong-name
deploy_reset_resource_state
[[ "$INETSIM_DOMAIN_NAME" == cape-inetsim-appliance ]]

echo '[PASS] generalized appliance domain QGA injection and fresh-state defaults'

grep -Fq 'LIBVIRT_STORAGE_POOL:-' "$ROOT/lib/inetsim-vm.sh"
grep -Fq 'No active directory libvirt storage pool with at least 20 GiB free was found' "$ROOT/lib/compat.sh"
grep -Fq 'LIBVIRT_STORAGE_POOL="$d_storage_pool"' "$ROOT/lib/deploy.sh"

grep -Fq "sysctl -n net.ipv4.ip_forward" "$ROOT/lib/inetsim-vm.sh"
grep -Fq "sysctl -n net.ipv6.conf.all.forwarding" "$ROOT/lib/inetsim-vm.sh"
grep -Fq "default4=(0|1)" "$ROOT/lib/inetsim-vm.sh"
grep -Fq "default6=0" "$ROOT/lib/inetsim-vm.sh"
grep -Fq "runtime forwarding isolation is enforced" "$ROOT/lib/inetsim-vm.sh"

grep -Fq 'qga_file_write "$INETSIM_DOMAIN_NAME" "$AUTODEPLOY_ROOT/appliance/guest-configure.sh"' "$ROOT/lib/inetsim-vm.sh"
grep -Fq 'inetsim-guest-configure.log' "$ROOT/lib/inetsim-vm.sh"
grep -Fq "baked_script='/usr/local/sbin/cape-inetsim-guest-configure'" "$ROOT/lib/inetsim-vm.sh"
grep -Fq 'baked configurator could not be proven byte-identical' "$ROOT/lib/inetsim-vm.sh"
grep -Fq 'transport="baked-release-match"' "$ROOT/lib/inetsim-vm.sh"
grep -Fq '/bin/bash -x "$selected_script"' "$ROOT/lib/inetsim-vm.sh"
grep -Fq 'RELEASE_TAG="$d_release_tag"' "$ROOT/lib/deploy.sh"
grep -Fq 'RELEASE_SOURCE_COMMIT="$d_release_commit"' "$ROOT/lib/deploy.sh"


# Regression: a host may expose QGA guest-exec while denying guest-file-*.
# The deployer must then use only a byte-identical baked configurator.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
AD_LOG_ROOT="$TMP"
DEPLOYMENT_ID="qga-file-denied"
INETSIM_DOMAIN_NAME="cape-inetsim-appliance"
INETSIM_MANAGEMENT_MAC="52:54:00:aa:00:01"
INETSIM_ISOLATED_MAC="52:54:00:aa:00:02"
INETSIM_IP="192.168.200.2"

virsh(){ return 0; }
qga_wait(){ return 0; }
qga_file_write(){ echo "guest-file-open denied" >&2; return 1; }
inetsim_capture_guest_diagnostics(){ :; }
state_record_resource(){ printf '%s\n' "$*" >"$TMP/resource-record"; }
state_write_atomic(){ :; }

qga_exec_wait(){
  local dom="$1" path="$2"
  shift 2
  case "$path" in
    /usr/bin/sha256sum)
      sha256sum "$ROOT/appliance/guest-configure.sh"
      ;;
    /bin/bash)
      [[ "$1" == -x ]]
      [[ "$2" == /usr/local/sbin/cape-inetsim-guest-configure ]]
      ;;
    /bin/rm)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

inetsim_configure_guest
grep -Fq 'CONFIGURATOR_TRANSPORT=baked-release-match' "$TMP/${DEPLOYMENT_ID}-inetsim-guest-configure.log"
grep -Fq 'transport=baked-release-match' "$TMP/resource-record"

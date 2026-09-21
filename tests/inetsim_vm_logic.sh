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

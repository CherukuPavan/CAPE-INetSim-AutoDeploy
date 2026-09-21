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
echo '[PASS] generalized appliance domain QGA injection is idempotent'

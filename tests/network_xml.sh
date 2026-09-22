#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/isolated-network.sh"

xml="$(render_isolated_network_xml cape-inetsim-isolated capeisim0 192.168.200.0/24 192.168.200.1)"
grep -q '<name>cape-inetsim-isolated</name>' <<<"$xml"
grep -q "<bridge name='capeisim0'" <<<"$xml"
grep -q "<ip address='192.168.200.1' netmask='255.255.255.0'/>" <<<"$xml"
! grep -q '<forward' <<<"$xml"

facts="$(network_xml_facts <<<"$xml")"
[[ "$facts" == 'OK|cape-inetsim-isolated|capeisim0|192.168.200.1|192.168.200.0/24|no' ]]


# Regression: with pipefail enabled, do not pipe virsh directly into grep -q/-E.
# grep may exit as soon as it matches, causing virsh to receive SIGPIPE (141).
! grep -Eq 'virsh net-info .*\|[[:space:]]*grep[[:space:]].*-.*q|virsh net-info .*\|[[:space:]]*grep[[:space:]].*-.*E' "$ROOT/lib/isolated-network.sh"

virsh() {
  [[ "$1" == net-info ]] || return 2
  printf 'Name: test-network\nActive: yes\n'
  local i
  for ((i=0;i<20000;i++)); do
    printf 'Padding: %05d abcdefghijklmnopqrstuvwxyz0123456789\n' "$i"
  done
}
isolated_network_is_active test-network

echo '[PASS] isolated libvirt network XML has no forwarding/NAT'

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

echo '[PASS] isolated libvirt network XML has no forwarding/NAT'

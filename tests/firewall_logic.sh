#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/targets.sh"
source "$ROOT/lib/firewall.sh"

base="$(firewall_render_rules capeisim7)"
grep -Fq 'table inet cape_inetsim_autodeploy' <<<"$base"
grep -Fq 'iifname "capeisim7" ct state established,related accept' <<<"$base"
grep -Fq 'iifname "capeisim7" drop' <<<"$base"
grep -Fq 'oifname "capeisim7" drop' <<<"$base"
! grep -Fq 'table bridge cape_inetsim_autodeploy_l2' <<<"$base"

CAPE_TARGETS_JSON='[
  {"section":"win10","domain":"win10","management_bridge":"virbr0","management_mac":"52:54:00:11:22:33","ip":"192.168.122.100","phase":"nic-attached"},
  {"section":"win7","domain":"win7","management_bridge":"virbr0","management_mac":"52:54:00:11:22:44","ip":"192.168.122.101","phase":"cape-configured"}
]'
full="$(firewall_render_rules capeisim7 yes)"
grep -Fq 'iifname "virbr0" ether saddr 52:54:00:11:22:33 drop' <<<"$full"
grep -Fq 'iifname "virbr0" ip saddr 192.168.122.100 drop' <<<"$full"
grep -Fq 'iifname "virbr0" ether saddr 52:54:00:11:22:44 drop' <<<"$full"
grep -Fq 'iifname "virbr0" ip saddr 192.168.122.101 drop' <<<"$full"
grep -Fq 'table bridge cape_inetsim_autodeploy_l2' <<<"$full"
grep -Fq 'ether saddr 52:54:00:11:22:33 drop' <<<"$full"
grep -Fq 'ether saddr 52:54:00:11:22:44 drop' <<<"$full"
! grep -Eq '\baccept\b.*(52:54:00:11:22:33|52:54:00:11:22:44|192\.168\.122\.10[01])' <<<"$full"

unit="$(firewall_render_unit)"
grep -Fq 'ExecStartPre=-/usr/sbin/nft delete table inet cape_inetsim_autodeploy' <<<"$unit"
grep -Fq 'ExecStartPre=-/usr/sbin/nft delete table bridge cape_inetsim_autodeploy_l2' <<<"$unit"
grep -Fq 'ExecStart=/usr/sbin/nft -f /etc/cape-inetsim-autodeploy/firewall.nft' <<<"$unit"
grep -Fq 'ExecStop=-/usr/sbin/nft delete table bridge cape_inetsim_autodeploy_l2' <<<"$unit"

echo '[PASS] host firewall blocks isolated and Windows-management escape paths'

grep -q 'firewall_management_records' "$ROOT/lib/firewall.sh"
grep -q 'firewall_management_guards_match_all' "$ROOT/lib/firewall.sh"
grep -q 'Restored firewall is missing one or more Windows management egress guards' "$ROOT/lib/firewall.sh"
python3 - "$ROOT/bin/cape-inetsim-repair" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()
a=s.index("firewall_validate_management_antispof_all")
b=s.index("firewall_apply",a)
assert a < b
assert "repair will not mutate the analysis VM security baseline" in s
PY

#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/firewall.sh"

base="$(firewall_render_rules capeisim7)"
grep -Fq 'table inet cape_inetsim_autodeploy' <<<"$base"
grep -Fq 'iifname "capeisim7" ct state established,related accept' <<<"$base"
grep -Fq 'iifname "capeisim7" drop' <<<"$base"
grep -Fq 'oifname "capeisim7" drop' <<<"$base"
! grep -Fq 'table bridge cape_inetsim_autodeploy_l2' <<<"$base"

full="$(firewall_render_rules capeisim7 virbr0 52:54:00:11:22:33 192.168.122.100)"
grep -Fq 'iifname "virbr0" ether saddr 52:54:00:11:22:33 drop' <<<"$full"
grep -Fq 'iifname "virbr0" ip saddr 192.168.122.100 drop' <<<"$full"
grep -Fq 'table bridge cape_inetsim_autodeploy_l2' <<<"$full"
grep -Fq 'ether saddr 52:54:00:11:22:33 drop' <<<"$full"
! grep -Eq '\baccept\b.*(52:54:00:11:22:33|192\.168\.122\.100)' <<<"$full"

unit="$(firewall_render_unit)"
grep -Fq 'ExecStartPre=-/usr/sbin/nft delete table inet cape_inetsim_autodeploy' <<<"$unit"
grep -Fq 'ExecStartPre=-/usr/sbin/nft delete table bridge cape_inetsim_autodeploy_l2' <<<"$unit"
grep -Fq 'ExecStart=/usr/sbin/nft -f /etc/cape-inetsim-autodeploy/firewall.nft' <<<"$unit"
grep -Fq 'ExecStop=-/usr/sbin/nft delete table bridge cape_inetsim_autodeploy_l2' <<<"$unit"

echo '[PASS] host firewall blocks isolated and Windows-management escape paths'

grep -q 'want_management=yes' "$ROOT/lib/firewall.sh"
grep -q 'state_resource_owned firewall-management-guard' "$ROOT/lib/firewall.sh"
grep -q 'Restored firewall is missing the Windows management egress guard' "$ROOT/lib/firewall.sh"
python3 - "$ROOT/bin/cape-inetsim-repair" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()
a=s.index("windows_management_guard_verify")
b=s.index("firewall_apply",a)
assert a < b
assert "repair will not mutate the analysis VM security baseline" in s
PY

#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/firewall.sh"

rules="$(firewall_render_rules capeisim7)"
grep -Fq 'table inet cape_inetsim_autodeploy' <<<"$rules"
grep -Fq 'iifname "capeisim7" ct state established,related accept' <<<"$rules"
grep -Fq 'iifname "capeisim7" drop' <<<"$rules"
grep -Fq 'oifname "capeisim7" drop' <<<"$rules"
! grep -Eq '\baccept\b.*iifname "capeisim7".*new' <<<"$rules"

unit="$(firewall_render_unit)"
grep -Fq 'ExecStartPre=-/usr/sbin/nft delete table inet cape_inetsim_autodeploy' <<<"$unit"
grep -Fq 'ExecStart=/usr/sbin/nft -f /etc/cape-inetsim-autodeploy/firewall.nft' <<<"$unit"
grep -Fq 'ExecStop=-/usr/sbin/nft delete table inet cape_inetsim_autodeploy' <<<"$unit"

echo '[PASS] isolated bridge host firewall blocks input/forward escape paths'

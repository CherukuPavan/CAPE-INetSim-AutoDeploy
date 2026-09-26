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
  {"section":"win10","domain":"win10","management_bridge":"virbr0","management_mac":"52:54:00:11:22:33","ip":"192.168.122.100","fake_ip":"192.168.200.10","resultserver_ip":"192.168.122.1","resultserver_port":"2042","phase":"nic-attached"},
  {"section":"win7","domain":"win7","management_bridge":"virbr0","management_mac":"52:54:00:11:22:44","ip":"192.168.122.101","fake_ip":"192.168.200.11","resultserver_ip":"192.168.122.1","resultserver_port":"2042","phase":"cape-configured"}
]'
full="$(firewall_render_rules capeisim7 yes)"
grep -Fq 'CAPE_INETSIM_ROUTE_AWARE_FIREWALL_V2' <<<"$full"
grep -Fq 'iifname "capeisim7" ip saddr 192.168.200.10 ip daddr 192.168.122.1 tcp dport 2042 accept' <<<"$full"
grep -Fq 'iifname "capeisim7" ip saddr 192.168.200.11 ip daddr 192.168.122.1 tcp dport 2042 accept' <<<"$full"
! grep -Fq 'iifname "virbr0" ip saddr 192.168.122.100 drop' <<<"$full"
! grep -Fq 'iifname "virbr0" ether saddr 52:54:00:11:22:33 drop' <<<"$full"
! grep -Fq 'table bridge cape_inetsim_autodeploy_l2' <<<"$full"
! grep -Fq 'iifname "capeisim7" accept' <<<"$full"

unit="$(firewall_render_unit)"
grep -Fq 'ExecStartPre=-/usr/sbin/nft delete table inet cape_inetsim_autodeploy' <<<"$unit"
grep -Fq 'ExecStartPre=-/usr/sbin/nft delete table bridge cape_inetsim_autodeploy_l2' <<<"$unit"
grep -Fq 'ExecStart=/usr/sbin/nft -f /etc/cape-inetsim-autodeploy/firewall.nft' <<<"$unit"
grep -Fq 'ExecStop=-/usr/sbin/nft delete table bridge cape_inetsim_autodeploy_l2' <<<"$unit"

echo '[PASS] host firewall keeps isolated network fail-closed without overriding CAPE task routes'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "$full" >"$TMP/full.nft"

# Route-aware upgrade regression: an RC44 bridge-table management guard must
# be removed atomically while the isolated inet guard is replaced.
firewall_table_exists(){ return 0; }
firewall_bridge_table_exists(){ return 1; }
runtime_batch="$(firewall_render_runtime_batch "$TMP/full.nft")"
[[ "$(head -n1 <<<"$runtime_batch")" == "delete table inet cape_inetsim_autodeploy" ]]
grep -Fq 'table inet cape_inetsim_autodeploy' <<<"$runtime_batch"
! grep -Fq 'delete table bridge cape_inetsim_autodeploy_l2' <<<"$runtime_batch"

firewall_bridge_table_exists(){ return 0; }
runtime_batch="$(firewall_render_runtime_batch "$TMP/full.nft")"
grep -Fq 'delete table inet cape_inetsim_autodeploy' <<<"$runtime_batch"
grep -Fq 'delete table bridge cape_inetsim_autodeploy_l2' <<<"$runtime_batch"
printf '%s\n' "$runtime_batch" >"$TMP/runtime.nft"

# An already-active RemainAfterExit unit must receive the checked nft batch
# directly; "enable --now" alone would leave the old base rules in memory.
LOG="$TMP/activate.log"
systemctl(){
  printf 'systemctl:%s\n' "$*" >>"$LOG"
  [[ "$1" == "is-active" ]] && return 0
  return 0
}
nft(){ printf 'nft:%s\n' "$*" >>"$LOG"; }
firewall_activate_rules "$TMP/runtime.nft"
grep -Fxq "nft:-f $TMP/runtime.nft" "$LOG"
grep -Fxq 'systemctl:enable cape-inetsim-autodeploy-firewall.service' "$LOG"
! grep -Fq 'systemctl:enable --now cape-inetsim-autodeploy-firewall.service' "$LOG"

# When the unit is not active, normal first-start behavior remains unchanged.
: >"$LOG"
systemctl(){
  printf 'systemctl:%s\n' "$*" >>"$LOG"
  [[ "$1" == "is-active" ]] && return 1
  return 0
}
firewall_activate_rules "$TMP/runtime.nft"
grep -Fxq 'systemctl:enable --now cape-inetsim-autodeploy-firewall.service' "$LOG"
! grep -Fq 'nft:-f ' "$LOG"

grep -Fq 'nft -c -f "$tmp_runtime_batch"' "$ROOT/lib/firewall.sh"
grep -Fq 'firewall_activate_rules "$tmp_runtime_batch"' "$ROOT/lib/firewall.sh"
echo '[PASS] active firewall rules are atomically replaced during route-aware upgrade'

grep -Fq 'CAPE_INETSIM_ROUTE_AWARE_FIREWALL_V2' "$ROOT/lib/firewall.sh"
grep -q 'firewall_isolated_resultserver_records' "$ROOT/lib/firewall.sh"
grep -q 'firewall_file_has_resultserver_exceptions_all' "$ROOT/lib/firewall.sh"
grep -q 'firewall_resultserver_exceptions_match_all' "$ROOT/lib/firewall.sh"
! grep -q 'Restored firewall is missing one or more Windows management egress guards' "$ROOT/lib/firewall.sh"
python3 - "$ROOT/bin/cape-inetsim-repair" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()
a=s.index("firewall_validate_management_antispof_all")
b=s.index("firewall_apply",a)
assert a < b
assert "repair will not mutate the analysis VM security baseline" in s
PY

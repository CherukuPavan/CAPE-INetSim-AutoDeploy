#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/targets.sh"
source "$ROOT/lib/firewall.sh"

ISOLATED_BRIDGE_NAME=capeisim7
INETSIM_IP=192.168.200.2
CAPE_TARGETS_JSON='[
  {"section":"win10","domain":"win10","management_bridge":"virbr0","ip":"192.168.122.100","phase":"discovered"},
  {"section":"win7","domain":"win7","management_bridge":"virbr0","ip":"192.168.122.101","phase":"discovered"}
]'

full="$(firewall_render_rules "$ISOLATED_BRIDGE_NAME")"
grep -Fq 'table inet cape_inetsim_autodeploy' <<<"$full"
grep -Fq 'iifname "virbr0" ip saddr 192.168.122.100 oifname "capeisim7" ip daddr 192.168.200.2 accept' <<<"$full"
grep -Fq 'iifname "virbr0" ip saddr 192.168.122.101 oifname "capeisim7" ip daddr 192.168.200.2 accept' <<<"$full"
grep -Fq 'iifname "capeisim7" drop' <<<"$full"
grep -Fq 'oifname "capeisim7" drop' <<<"$full"
! grep -Fq 'ip saddr 192.168.122.100 drop' <<<"$full"
! grep -Fq 'table bridge cape_inetsim_autodeploy_l2' <<<"$full"

echo '[PASS] firewall permits only CAPE-to-INetSim forwarding on the isolated bridge'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "$full" >"$TMP/full.nft"

firewall_table_exists(){ return 0; }
firewall_bridge_table_exists(){ return 1; }
runtime_batch="$(firewall_render_runtime_batch "$TMP/full.nft")"
[[ "$(head -n1 <<<"$runtime_batch")" == "delete table inet cape_inetsim_autodeploy" ]]
grep -Fq 'table inet cape_inetsim_autodeploy' <<<"$runtime_batch"

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

grep -Fq 'firewall_inetsim_client_records' "$ROOT/lib/firewall.sh"
grep -Fq 'firewall_inetsim_route_exceptions_match_all' "$ROOT/lib/firewall.sh"
echo '[PASS] active firewall rules are atomically replaced for route separation'

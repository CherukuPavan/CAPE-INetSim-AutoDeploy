#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/targets.sh"
source "$ROOT/lib/firewall.sh"

INETSIM_IP=192.168.200.2
base="$(firewall_render_rules capeisim7)"

grep -Fq 'table inet cape_inetsim_autodeploy' <<<"$base"
grep -Fq 'oifname "capeisim7" ip daddr 192.168.200.2 ct status dnat accept' <<<"$base"
grep -Fq 'iifname "capeisim7" ip saddr 192.168.200.2 ct state established,related accept' <<<"$base"
grep -Fq 'iifname "capeisim7" drop' <<<"$base"
grep -Fq 'oifname "capeisim7" drop' <<<"$base"

# Route-scoped mode must not contain a permanent management-NIC block or
# legacy fake-NIC ResultServer exception. CAPE rooter owns per-task forwarding.
! grep -Fq 'table bridge cape_inetsim_autodeploy_l2' <<<"$base"
! grep -Fq 'virbr0' <<<"$base"
! grep -Fq '2042 accept' <<<"$base"

echo '[PASS] isolated bridge permits only CAPE-DNATed INetSim flows and established replies'

unit="$(firewall_render_unit)"
grep -Fq 'ExecStartPre=-/usr/sbin/nft delete table inet cape_inetsim_autodeploy' <<<"$unit"
grep -Fq 'ExecStart=/usr/sbin/nft -f /etc/cape-inetsim-autodeploy/firewall.nft' <<<"$unit"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "$base" >"$TMP/full.nft"

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
firewall_activate_rules "$TMP/full.nft"
grep -Fxq "nft:-f $TMP/full.nft" "$LOG"
grep -Fxq 'systemctl:enable cape-inetsim-autodeploy-firewall.service' "$LOG"

: >"$LOG"
systemctl(){
  printf 'systemctl:%s\n' "$*" >>"$LOG"
  [[ "$1" == "is-active" ]] && return 1
  return 0
}
firewall_activate_rules "$TMP/full.nft"
grep -Fxq 'systemctl:enable --now cape-inetsim-autodeploy-firewall.service' "$LOG"
! grep -Fq 'nft:-f ' "$LOG"

grep -Fq 'ct status dnat accept' "$ROOT/lib/firewall.sh"
grep -Fq 'Route-scoped mode must not install a permanent management-NIC egress' "$ROOT/lib/firewall.sh"

echo '[PASS] route-scoped firewall lifecycle preserves CAPE per-task routing ownership'

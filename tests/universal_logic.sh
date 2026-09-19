#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/cape.sh"
source "$ROOT/lib/libvirt.sh"
source "$ROOT/lib/network.sh"

CAPE_MACHINE_RECORDS=(
  '{"section":"cape1","label":"cape1","ip":"192.168.122.105","snapshot":"old"}'
  '{"section":"win10","label":"win10","ip":"192.168.122.100","snapshot":"snapshot1"}'
)
LIBVIRT_DOMAINS=(win10)
REQUESTED_MACHINE=""
DISCOVERY_ERRORS=()
SELECTED_MACHINE_JSON=""
auto_select_cape_machine
[[ "$CAPE_MACHINE_SECTION" == "win10" ]]

CAPE_MACHINE_RECORDS=(
  '{"section":"cape1","label":"cape1","ip":"192.168.122.105","snapshot":"old"}'
  '{"section":"cuckoo1","label":"cuckoo1","ip":"192.168.122.100","snapshot":"snap2"}'
)
LIBVIRT_DOMAINS=(cuckoo1 ubuntu24.04)
REQUESTED_MACHINE=""
DISCOVERY_ERRORS=()
SELECTED_MACHINE_JSON=""
auto_select_cape_machine
[[ "$CAPE_MACHINE_SECTION" == "cuckoo1" ]]

collect_used_cidrs(){ printf '%s\n' '192.168.200.0/24' '192.168.122.0/24'; }
DISCOVERY_ERRORS=()
plan_isolated_subnet
[[ "$ISOLATED_SUBNET" != "192.168.200.0/24" ]]
[[ -n "$BRIDGE_IP" && -n "$INETSIM_IP" && -n "$WINDOWS_FAKE_IP" ]]

echo "[PASS] universal machine selection and subnet fallback"

#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
AD_STATE_ROOT="$TMP/state"
AD_STATE_FILE="$AD_STATE_ROOT/state.env"
AD_RESOURCE_LEDGER="$AD_STATE_ROOT/resources.tsv"
AD_BACKUP_ROOT="$AD_STATE_ROOT/backups"
AD_GENERATED_ROOT="$AD_STATE_ROOT/generated"
AD_LOG_ROOT="$AD_STATE_ROOT/logs"
source "$ROOT/lib/state.sh"

state_init_paths
state_new_deployment_id
DEPLOYMENT_PHASE=planned
CAPE_ROOT=/opt/CAPEv2
CAPE_MACHINE_SECTION=win10
DOMAIN=win10
ISOLATED_SUBNET=192.168.200.0/24
BRIDGE_IP=192.168.200.1
INETSIM_IP=192.168.200.2
WINDOWS_FAKE_IP=192.168.200.10
ISOLATED_NETWORK_NAME=cape-inetsim-isolated
ISOLATED_BRIDGE_NAME=capeisim0
state_write_atomic
state_record_resource libvirt-network cape-inetsim-isolated defined yes 'bridge=capeisim0'

unset DEPLOYMENT_PHASE CAPE_ROOT CAPE_MACHINE_SECTION DOMAIN ISOLATED_SUBNET BRIDGE_IP INETSIM_IP WINDOWS_FAKE_IP ISOLATED_NETWORK_NAME ISOLATED_BRIDGE_NAME
state_load
[[ "$DEPLOYMENT_PHASE" == planned ]]
[[ "$CAPE_ROOT" == /opt/CAPEv2 ]]
[[ "$DOMAIN" == win10 ]]
[[ "$INETSIM_IP" == 192.168.200.2 ]]
state_resource_owned libvirt-network cape-inetsim-isolated
! state_resource_owned libvirt-network foreign-network

echo '[PASS] state persistence and ownership ledger'

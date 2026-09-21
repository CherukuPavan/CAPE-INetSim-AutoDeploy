#!/usr/bin/env bash

AD_STATE_ROOT="${AD_STATE_ROOT:-/var/lib/cape-inetsim-autodeploy}"
AD_STATE_FILE="${AD_STATE_FILE:-$AD_STATE_ROOT/state.env}"
AD_RESOURCE_LEDGER="${AD_RESOURCE_LEDGER:-$AD_STATE_ROOT/resources.tsv}"
AD_BACKUP_ROOT="${AD_BACKUP_ROOT:-$AD_STATE_ROOT/backups}"
AD_GENERATED_ROOT="${AD_GENERATED_ROOT:-$AD_STATE_ROOT/generated}"
AD_LOG_ROOT="${AD_LOG_ROOT:-$AD_STATE_ROOT/logs}"
AD_LOCK_FILE="${AD_LOCK_FILE:-/run/lock/cape-inetsim-autodeploy.lock}"

state_init_paths() {
  install -d -m 0700 "$AD_STATE_ROOT" "$AD_BACKUP_ROOT" "$AD_GENERATED_ROOT" "$AD_LOG_ROOT"
  if [[ ! -e "$AD_RESOURCE_LEDGER" ]]; then
    printf 'kind\tname\taction\tcreated_by_autodeploy\tdetail\n' >"$AD_RESOURCE_LEDGER"
    chmod 0600 "$AD_RESOURCE_LEDGER"
  fi
}

state_write_atomic() {
  local tmp
  tmp="$(mktemp "$AD_STATE_ROOT/.state.XXXXXX")"
  {
    echo '# CAPE-INetSim-AutoDeploy state; shell-quoted values; root-readable only.'
    printf 'STATE_SCHEMA=%q\n' "1"
    printf 'DEPLOYMENT_ID=%q\n' "${DEPLOYMENT_ID:-}"
    printf 'DEPLOYMENT_PHASE=%q\n' "${DEPLOYMENT_PHASE:-discovered}"
    printf 'CAPE_ROOT=%q\n' "${CAPE_ROOT:-}"
    printf 'CAPE_COMMIT=%q\n' "${CAPE_COMMIT:-}"
    printf 'CAPE_MACHINE_SECTION=%q\n' "${CAPE_MACHINE_SECTION:-}"
    printf 'CAPE_MACHINE_LABEL=%q\n' "${CAPE_MACHINE_LABEL:-}"
    printf 'CAPE_MACHINE_IP=%q\n' "${CAPE_MACHINE_IP:-}"
    printf 'CAPE_RESULTSERVER_IP=%q\n' "${CAPE_RESULTSERVER_IP:-}"
    printf 'CAPE_RESULTSERVER_PORT=%q\n' "${CAPE_RESULTSERVER_PORT:-}"
    printf 'CONTROL_HOST_IP=%q\n' "${CONTROL_HOST_IP:-}"
    printf 'DOMAIN=%q\n' "${DOMAIN:-}"
    printf 'MANAGEMENT_NETWORK_NAME=%q\n' "${MANAGEMENT_NETWORK_NAME:-}"
    printf 'ORIGINAL_CAPE_SNAPSHOT=%q\n' "${CAPE_MACHINE_SNAPSHOT:-}"
    printf 'ISOLATED_SUBNET=%q\n' "${ISOLATED_SUBNET:-}"
    printf 'BRIDGE_IP=%q\n' "${BRIDGE_IP:-}"
    printf 'INETSIM_IP=%q\n' "${INETSIM_IP:-}"
    printf 'WINDOWS_FAKE_IP=%q\n' "${WINDOWS_FAKE_IP:-}"
    printf 'ISOLATED_NETWORK_NAME=%q\n' "${ISOLATED_NETWORK_NAME:-}"
    printf 'ISOLATED_BRIDGE_NAME=%q\n' "${ISOLATED_BRIDGE_NAME:-}"
    printf 'WINDOWS_ISOLATED_NIC_MODEL=%q\n' "${WINDOWS_ISOLATED_NIC_MODEL:-}"
    printf 'WINDOWS_ISOLATED_MAC=%q\n' "${WINDOWS_ISOLATED_MAC:-}"
    printf 'SAFETY_SNAPSHOT=%q\n' "${SAFETY_SNAPSHOT:-}"
    printf 'FINAL_SNAPSHOT=%q\n' "${FINAL_SNAPSHOT:-}"
    printf 'STATE_UPDATED_AT=%q\n' "$(date -Is)"
  } >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$AD_STATE_FILE"
}

state_load() {
  [[ -f "$AD_STATE_FILE" ]] || return 1
  # File is created only by AutoDeploy under a root-only directory.
  # shellcheck disable=SC1090
  source "$AD_STATE_FILE"
}

state_set_phase() {
  DEPLOYMENT_PHASE="$1"
  state_write_atomic
}

state_record_resource() {
  local kind="$1" name="$2" action="$3" created="$4" detail="${5:-}"
  state_init_paths
  printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$name" "$action" "$created" "${detail//$'\t'/ }" >>"$AD_RESOURCE_LEDGER"
}

state_resource_owned() {
  local kind="$1" name="$2"
  [[ -f "$AD_RESOURCE_LEDGER" ]] || return 1
  awk -F '\t' -v k="$kind" -v n="$name" '
    NR>1 && $1==k && $2==n {created=$4; action=$3; seen=1}
    END {
      if (!seen) exit 1
      if (created!="yes") exit 1
      if (action ~ /^(removed|restored|released)/) exit 1
      exit 0
    }' "$AD_RESOURCE_LEDGER"
}

state_new_deployment_id() {
  DEPLOYMENT_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(hostname -s | tr -cs 'A-Za-z0-9._-' '-')-$$"
}

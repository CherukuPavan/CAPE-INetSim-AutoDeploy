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
AD_LOCK_FILE="$TMP/lock"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/transaction.sh"

state_init_paths
state_new_deployment_id
src="$TMP/original.conf"
printf 'before\n' >"$src"
backup_file_once "$src" conf/original.conf
printf 'after\n' >"$src"
restore_backup_file "$src" conf/original.conf
[[ "$(cat "$src")" == before ]]
[[ -f "$AD_BACKUP_ROOT/$DEPLOYMENT_ID/conf/original.conf.sha256" ]]

echo '[PASS] backup checksum and restore logic'

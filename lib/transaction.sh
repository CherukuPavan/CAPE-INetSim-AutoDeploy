#!/usr/bin/env bash

transaction_lock_acquire() {
  local lock_dir
  lock_dir="$(dirname "$AD_LOCK_FILE")"
  install -d -m 0755 "$lock_dir"
  exec {AD_LOCK_FD}>"$AD_LOCK_FILE"
  flock -n "$AD_LOCK_FD" || {
    echo "[FAIL] Another CAPE-INetSim-AutoDeploy operation holds $AD_LOCK_FILE" >&2
    return 1
  }
}

backup_file_once() {
  local src="$1" rel="$2"
  [[ -e "$src" ]] || return 0
  local dst="$AD_BACKUP_ROOT/${DEPLOYMENT_ID}/${rel}"
  if [[ -e "$dst" ]]; then return 0; fi
  install -d -m 0700 "$(dirname "$dst")"
  cp -a -- "$src" "$dst"
  sha256sum "$dst" >"${dst}.sha256"
  state_record_resource "backup" "$src" "copied" "yes" "$dst"
}

restore_backup_file() {
  local src="$1" rel="$2"
  local backup="$AD_BACKUP_ROOT/${DEPLOYMENT_ID}/${rel}"
  [[ -e "$backup" ]] || return 1
  if [[ -f "${backup}.sha256" ]]; then
    (cd "$(dirname "$backup")" && sha256sum -c "$(basename "${backup}.sha256")") >/dev/null
  fi
  cp -a -- "$backup" "$src"
}

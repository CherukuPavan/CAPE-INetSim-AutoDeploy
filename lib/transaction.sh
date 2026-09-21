#!/usr/bin/env bash

txn_lock() {
  state_prepare_dirs
  local lock
  lock="$(state_root)/deploy.lock"
  exec {AD_LOCK_FD}>"$lock"
  flock -n "$AD_LOCK_FD" || { fail "Another AutoDeploy operation is running"; return 1; }
}

txn_backup_file_once() {
  local src="$1"
  [[ -e "$src" ]] || { fail "Cannot back up missing path: $src"; return 1; }
  local root rel dst manifest
  root="$(backup_root)"
  rel="${src#/}"
  dst="$root/$rel"
  manifest="$root/MANIFEST.tsv"
  if [[ -e "$dst" ]]; then
    return 0
  fi
  install -d -m 0750 "$(dirname "$dst")"
  cp -a -- "$src" "$dst"
  local sha mode owner group
  sha="$(sha256sum "$src" | awk '{print $1}')"
  mode="$(stat -c '%a' "$src")"
  owner="$(stat -c '%U' "$src")"
  group="$(stat -c '%G' "$src")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$src" "$sha" "$mode" "$owner" "$group" >>"$manifest"
  chmod 0640 "$manifest"
}

txn_restore_backups() {
  local manifest root src sha mode owner group rel dst
  root="$(backup_root)"
  manifest="$root/MANIFEST.tsv"
  [[ -f "$manifest" ]] || return 0
  while IFS=$'\t' read -r src sha mode owner group; do
    [[ -n "$src" ]] || continue
    rel="${src#/}"
    dst="$root/$rel"
    [[ -e "$dst" ]] || { warn "Backup payload missing for $src"; continue; }
    cp -a -- "$dst" "$src"
  done <"$manifest"
}

txn_record_resource() {
  local type="$1" id="$2" detail="${3:-}"
  local f
  f="$(resource_file)"
  grep -Fqx "$type"$'\t'"$id"$'\t'"$detail" "$f" 2>/dev/null ||     printf '%s\t%s\t%s\n' "$type" "$id" "$detail" >>"$f"
}

txn_has_resource() {
  local type="$1" id="$2"
  grep -Fq "$type"$'\t'"$id"$'\t' "$(resource_file)" 2>/dev/null
}

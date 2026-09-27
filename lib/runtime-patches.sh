#!/usr/bin/env bash

cape_runtime_patch_files() {
  printf '%s\n' \
    utils/rooter.py \
    lib/cuckoo/core/analysis_manager.py \
    modules/processing/network.py \
    modules/processing/autodeploy_task_network.py \
    web/templates/submission/index.html
}

cape_runtime_patch_backup_files() {
  local rel
  for rel in $(cape_runtime_patch_files); do
    if [[ -e "$CAPE_ROOT/$rel" ]]; then
      backup_file_once "$CAPE_ROOT/$rel" "$rel"
      state_record_resource cape-file "$CAPE_ROOT/$rel" planned-modification yes \
        "backup=$AD_BACKUP_ROOT/${DEPLOYMENT_ID}/$rel"
    else
      state_record_resource cape-file "$CAPE_ROOT/$rel" planned-creation yes \
        "file absent before RC66; rollback removes only if post-hash matches"
    fi
  done
}

cape_runtime_patch_apply() {
  local helper="$AUTODEPLOY_ROOT/tools/task_network_filter.py"
  local patcher="$AUTODEPLOY_ROOT/tools/patch_cape_runtime.py"

  [[ -f "$helper" && -f "$patcher" ]] || {
    fail "Runtime route/filter patch tools are missing"
    return 1
  }

  python3 "$patcher" --root "$CAPE_ROOT" --helper-source "$helper"

  local py
  py="$(cape_runtime_python)"
  "$py" -m py_compile \
    "$CAPE_ROOT/utils/rooter.py" \
    "$CAPE_ROOT/lib/cuckoo/core/analysis_manager.py" \
    "$CAPE_ROOT/modules/processing/network.py" \
    "$CAPE_ROOT/modules/processing/autodeploy_task_network.py"

  grep -Fq 'CAPE_INETSIM_AUTODEPLOY_ROUTE_V4' "$CAPE_ROOT/utils/rooter.py"
  grep -Fq 'CAPE_INETSIM_AUTODEPLOY_TASK_NETWORK_V2' "$CAPE_ROOT/modules/processing/network.py"
  grep -Fq 'CAPE_INETSIM_AUTODEPLOY_ROUTE_UI_V2' "$CAPE_ROOT/web/templates/submission/index.html"

  state_record_resource cape-file "$CAPE_ROOT/utils/rooter.py" modified yes "per-task-route-policy"
  state_record_resource cape-file "$CAPE_ROOT/lib/cuckoo/core/analysis_manager.py" modified yes "stale-route-policy-reset"
  state_record_resource cape-file "$CAPE_ROOT/modules/processing/network.py" modified yes "task-attributed-network-view"
  state_record_resource cape-file "$CAPE_ROOT/modules/processing/autodeploy_task_network.py" modified yes "task-network-filter"
  state_record_resource cape-file "$CAPE_ROOT/web/templates/submission/index.html" modified yes "route-semantics-ui"
}

cape_runtime_patch_restore_files() {
  local rel expected current backup backup_sha failures=0

  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue

    backup="$AD_BACKUP_ROOT/${DEPLOYMENT_ID}/$rel"
    current="$(sha256sum "$CAPE_ROOT/$rel" 2>/dev/null | awk '{print $1}' || true)"
    expected="$(cape_post_sha_for_rel "$rel" 2>/dev/null || true)"

    if [[ -e "$backup" ]]; then
      backup_sha="$(sha256sum "$backup" | awk '{print $1}')"
      if [[ "$current" == "$backup_sha" ]]; then
        state_record_resource cape-file "$CAPE_ROOT/$rel" restored yes "already-predeployment"
        continue
      fi
      if [[ -n "$expected" && "$current" != "$expected" ]]; then
        fail "Refusing to rollback CAPE runtime file changed after AutoDeploy: $rel"
        failures=$((failures+1))
        continue
      fi
      if restore_backup_file "$CAPE_ROOT/$rel" "$rel"; then
        state_record_resource cape-file "$CAPE_ROOT/$rel" restored yes ""
      else
        failures=$((failures+1))
      fi
      continue
    fi

    if [[ -e "$CAPE_ROOT/$rel" ]]; then
      if [[ -n "$expected" && "$current" == "$expected" ]] &&
         state_resource_owned cape-file "$CAPE_ROOT/$rel"; then
        rm -f -- "$CAPE_ROOT/$rel"
        state_record_resource cape-file "$CAPE_ROOT/$rel" removed-by-rollback yes \
          "file was absent before RC66"
      else
        fail "Refusing to remove unbacked CAPE runtime file with ownership/hash mismatch: $rel"
        failures=$((failures+1))
      fi
    fi
  done < <(cape_runtime_patch_files)

  ((failures == 0))
}

#!/usr/bin/env bash

cape_runtime_patch_files() {
  printf '%s\n' \
    utils/rooter.py \
    lib/cuckoo/core/analysis_manager.py \
    modules/processing/network.py \
    modules/processing/autodeploy_task_network.py \
    web/templates/submission/index.html
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

  grep -Fq 'CAPE_INETSIM_AUTODEPLOY_ROUTE_V3' "$CAPE_ROOT/utils/rooter.py"
  grep -Fq 'CAPE_INETSIM_AUTODEPLOY_ROUTE_V3' "$CAPE_ROOT/lib/cuckoo/core/analysis_manager.py"
  grep -Fq 'CAPE_INETSIM_AUTODEPLOY_TASK_NETWORK_V1' "$CAPE_ROOT/modules/processing/network.py"
  grep -Fq 'CAPE_INETSIM_AUTODEPLOY_ROUTE_UI_V1' "$CAPE_ROOT/web/templates/submission/index.html"

  state_record_resource cape-file "$CAPE_ROOT/utils/rooter.py" modified yes "strict-drop-route-policy"
  state_record_resource cape-file "$CAPE_ROOT/lib/cuckoo/core/analysis_manager.py" modified yes "exclusive-internet-inetsim-drop-policy"
  state_record_resource cape-file "$CAPE_ROOT/modules/processing/network.py" modified yes "task-attributed-network-view"
  state_record_resource cape-file "$CAPE_ROOT/modules/processing/autodeploy_task_network.py" modified yes "vendor-task-network-filter"
  state_record_resource cape-file "$CAPE_ROOT/web/templates/submission/index.html" modified yes "explicit-route-semantics"
}

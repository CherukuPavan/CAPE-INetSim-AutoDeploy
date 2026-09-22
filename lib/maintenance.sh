#!/usr/bin/env bash

CAPE_MAINTENANCE_GUARD_FILE="${CAPE_MAINTENANCE_GUARD_FILE:-$AD_STATE_ROOT/cape-maintenance-guard.json}"

discover_cape_runtime() {
  CAPE_SERVICE_USER="$(systemctl show cape.service -p User --value 2>/dev/null || true)"
  [[ -n "$CAPE_SERVICE_USER" ]] || CAPE_SERVICE_USER=root
  if [[ -n "${CAPE_RUNTIME_PYTHON:-}" && -x "$CAPE_RUNTIME_PYTHON" ]]; then
    return 0
  fi
  local pid
  pid="$(systemctl show cape.service -p MainPID --value 2>/dev/null || true)"
  CAPE_RUNTIME_PYTHON=""
  if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]]; then
    CAPE_RUNTIME_PYTHON="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
  fi
  if [[ -z "$CAPE_RUNTIME_PYTHON" ]]; then
    CAPE_RUNTIME_PYTHON="$(cape_runtime_python 2>/dev/null || true)"
  fi
  [[ -x "$CAPE_RUNTIME_PYTHON" ]] || { fail "Could not discover CAPE runtime Python"; return 1; }
}

cape_maintenance_tool() {
  local action="$1"
  discover_cape_runtime
  install -d -m 0700 "$AD_STATE_ROOT"
  if [[ "$CAPE_SERVICE_USER" == root ]]; then
    (cd "$CAPE_ROOT" && env PYTHONPATH="$CAPE_ROOT" "$CAPE_RUNTIME_PYTHON" "$AUTODEPLOY_ROOT/tools/cape_maintenance.py" "$action" --label "$CAPE_MACHINE_LABEL" --deployment-id "$DEPLOYMENT_ID" --guard-file "$CAPE_MAINTENANCE_GUARD_FILE")
  else
    # Use a stable CAPE-user staging path so a process crash cannot orphan the
    # DB lock between commit and the root-owned guard copy.
    local user_dir="/tmp/cape-inetsim-autodeploy-$DEPLOYMENT_ID"
    [[ ! -L "$user_dir" ]] || { fail "Unsafe CAPE maintenance staging symlink: $user_dir"; return 1; }
    install -d -m 0700 -o "$CAPE_SERVICE_USER" "$user_dir"
    local user_guard="$user_dir/guard.json"

    if [[ "$action" == acquire ]]; then
      if [[ -f "$user_guard" ]]; then
        if runuser -u "$CAPE_SERVICE_USER" -- env PYTHONPATH="$CAPE_ROOT" "$CAPE_RUNTIME_PYTHON" "$AUTODEPLOY_ROOT/tools/cape_maintenance.py" verify --label "$CAPE_MACHINE_LABEL" --deployment-id "$DEPLOYMENT_ID" --guard-file "$user_guard" >/dev/null 2>&1; then
          install -m 0600 -o root -g root "$user_guard" "$CAPE_MAINTENANCE_GUARD_FILE"
          rm -f "$user_guard" "$user_guard.pending"
          rmdir "$user_dir" 2>/dev/null || true
          return 0
        fi
      fi

      runuser -u "$CAPE_SERVICE_USER" -- env PYTHONPATH="$CAPE_ROOT" "$CAPE_RUNTIME_PYTHON" "$AUTODEPLOY_ROOT/tools/cape_maintenance.py" "$action" --label "$CAPE_MACHINE_LABEL" --deployment-id "$DEPLOYMENT_ID" --guard-file "$user_guard"
      if ! install -m 0600 -o root -g root "$user_guard" "$CAPE_MAINTENANCE_GUARD_FILE"; then
        # The DB locks are already committed. Immediately release them using
        # the CAPE-user guard rather than leaving machines orphan-locked.
        runuser -u "$CAPE_SERVICE_USER" -- env PYTHONPATH="$CAPE_ROOT" "$CAPE_RUNTIME_PYTHON" "$AUTODEPLOY_ROOT/tools/cape_maintenance.py" release --label "$CAPE_MACHINE_LABEL" --deployment-id "$DEPLOYMENT_ID" --guard-file "$user_guard" >/dev/null 2>&1 || true
        rm -f "$user_guard" "$user_guard.pending"
        rmdir "$user_dir" 2>/dev/null || true
        fail "Could not persist CAPE maintenance guard; locks were released"
        return 1
      fi
      rm -f "$user_guard" "$user_guard.pending"
      rmdir "$user_dir" 2>/dev/null || true
    elif [[ "$action" == release ]]; then
      install -m 0600 -o "$CAPE_SERVICE_USER" "$CAPE_MAINTENANCE_GUARD_FILE" "$user_guard" 2>/dev/null || {
        fail "Could not stage CAPE maintenance guard for release"
        return 1
      }
      local rc
      if runuser -u "$CAPE_SERVICE_USER" -- env PYTHONPATH="$CAPE_ROOT" "$CAPE_RUNTIME_PYTHON" "$AUTODEPLOY_ROOT/tools/cape_maintenance.py" "$action" --label "$CAPE_MACHINE_LABEL" --deployment-id "$DEPLOYMENT_ID" --guard-file "$user_guard"; then
        rc=0
      else
        rc=$?
      fi
      rm -f "$user_guard" "$user_guard.pending"
      rmdir "$user_dir" 2>/dev/null || true
      if [[ "$rc" -eq 0 ]]; then
        rm -f "$CAPE_MAINTENANCE_GUARD_FILE"
      else
        warn "CAPE maintenance release was incomplete; preserving recovery guard $CAPE_MAINTENANCE_GUARD_FILE"
      fi
      return "$rc"
    elif [[ "$action" == verify ]]; then
      install -m 0600 -o "$CAPE_SERVICE_USER" "$CAPE_MAINTENANCE_GUARD_FILE" "$user_guard" 2>/dev/null || {
        fail "Could not stage CAPE maintenance guard for verification"
        return 1
      }
      local rc
      if runuser -u "$CAPE_SERVICE_USER" -- env PYTHONPATH="$CAPE_ROOT" "$CAPE_RUNTIME_PYTHON" "$AUTODEPLOY_ROOT/tools/cape_maintenance.py" "$action" --label "$CAPE_MACHINE_LABEL" --deployment-id "$DEPLOYMENT_ID" --guard-file "$user_guard"; then
        rc=0
      else
        rc=$?
      fi
      rm -f "$user_guard" "$user_guard.pending"
      rmdir "$user_dir" 2>/dev/null || true
      return "$rc"
    else
      runuser -u "$CAPE_SERVICE_USER" -- env PYTHONPATH="$CAPE_ROOT" "$CAPE_RUNTIME_PYTHON" "$AUTODEPLOY_ROOT/tools/cape_maintenance.py" "$action" --label "$CAPE_MACHINE_LABEL" --deployment-id "$DEPLOYMENT_ID" --guard-file "$user_guard"
    fi
  fi
}

cape_wait_and_acquire_maintenance() {
  local timeout="${1:-3600}" elapsed=0 rc
  while ((elapsed < timeout)); do
    if cape_maintenance_tool acquire; then
      rc=0
    else
      rc=$?
    fi
    if [[ "$rc" -eq 0 ]]; then
      state_record_resource cape-maintenance all-machines acquired yes "$CAPE_MAINTENANCE_GUARD_FILE"
      pass "CAPE machine scheduling paused at a task-safe point"
      return 0
    fi
    [[ "$rc" -eq 20 ]] || return "$rc"
    info "CAPE is busy; waiting for running/distributed/processing work to finish..."
    sleep 15
    elapsed=$((elapsed+15))
  done
  fail "Timed out waiting for a safe CAPE cutover point"
  return 1
}

cape_release_maintenance() {
  [[ -f "$CAPE_MAINTENANCE_GUARD_FILE" ]] || return 0
  local rc
  if cape_maintenance_tool release; then
    rc=0
  else
    rc=$?
  fi
  if [[ "$rc" -eq 0 ]]; then
    state_record_resource cape-maintenance all-machines released yes ""
    return 0
  fi
  state_record_resource cape-maintenance all-machines release-incomplete yes "rc=$rc guard=$CAPE_MAINTENANCE_GUARD_FILE"
  fail "CAPE maintenance release incomplete; guard preserved for safe recovery"
  return "$rc"
}

cape_verify_maintenance_guard() {
  [[ -f "$CAPE_MAINTENANCE_GUARD_FILE" ]] || {
    fail "CAPE maintenance guard is missing"
    return 1
  }
  cape_maintenance_tool verify >/dev/null
}

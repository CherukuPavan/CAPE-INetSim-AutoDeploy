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
    # The checksum-pinned public bootstrap executes from a root-owned mktemp
    # directory (normally mode 0700). CAPE commonly runs as a non-root service
    # user, which therefore cannot traverse AUTODEPLOY_ROOT. Stage only this
    # small maintenance helper inside the existing CAPE-user transaction
    # directory instead of weakening the release directory permissions.
    local user_dir="/tmp/cape-inetsim-autodeploy-$DEPLOYMENT_ID"
    [[ ! -L "$user_dir" ]] || { fail "Unsafe CAPE maintenance staging symlink: $user_dir"; return 1; }
    install -d -m 0700 -o "$CAPE_SERVICE_USER" "$user_dir"
    local user_guard="$user_dir/guard.json"
    local user_tool="$user_dir/cape_maintenance.py"

    install -m 0500 -o "$CAPE_SERVICE_USER" "$AUTODEPLOY_ROOT/tools/cape_maintenance.py" "$user_tool" || {
      fail "Could not stage CAPE maintenance helper for service user"
      return 1
    }

    if [[ "$action" == acquire ]]; then
      if [[ -f "$user_guard" ]]; then
        if runuser -u "$CAPE_SERVICE_USER" -- env PYTHONPATH="$CAPE_ROOT" "$CAPE_RUNTIME_PYTHON" "$user_tool" verify --label "$CAPE_MACHINE_LABEL" --deployment-id "$DEPLOYMENT_ID" --guard-file "$user_guard" >/dev/null 2>&1; then
          install -m 0600 -o root -g root "$user_guard" "$CAPE_MAINTENANCE_GUARD_FILE"
          rm -f "$user_guard" "$user_guard.pending" "$user_tool"
          rmdir "$user_dir" 2>/dev/null || true
          return 0
        fi
      fi

      if ! runuser -u "$CAPE_SERVICE_USER" -- env PYTHONPATH="$CAPE_ROOT" "$CAPE_RUNTIME_PYTHON" "$user_tool" "$action" --label "$CAPE_MACHINE_LABEL" --deployment-id "$DEPLOYMENT_ID" --guard-file "$user_guard"; then
        local rc=$?
        rm -f "$user_tool"
        return "$rc"
      fi
      if ! install -m 0600 -o root -g root "$user_guard" "$CAPE_MAINTENANCE_GUARD_FILE"; then
        # The DB locks are already committed. Immediately release them using
        # the CAPE-user guard rather than leaving machines orphan-locked.
        runuser -u "$CAPE_SERVICE_USER" -- env PYTHONPATH="$CAPE_ROOT" "$CAPE_RUNTIME_PYTHON" "$user_tool" release --label "$CAPE_MACHINE_LABEL" --deployment-id "$DEPLOYMENT_ID" --guard-file "$user_guard" >/dev/null 2>&1 || true
        rm -f "$user_guard" "$user_guard.pending" "$user_tool"
        rmdir "$user_dir" 2>/dev/null || true
        fail "Could not persist CAPE maintenance guard; locks were released"
        return 1
      fi
      rm -f "$user_guard" "$user_guard.pending" "$user_tool"
      rmdir "$user_dir" 2>/dev/null || true
    elif [[ "$action" == release ]]; then
      install -m 0600 -o "$CAPE_SERVICE_USER" "$CAPE_MAINTENANCE_GUARD_FILE" "$user_guard" 2>/dev/null || {
        rm -f "$user_tool"
        fail "Could not stage CAPE maintenance guard for release"
        return 1
      }
      local rc
      if runuser -u "$CAPE_SERVICE_USER" -- env PYTHONPATH="$CAPE_ROOT" "$CAPE_RUNTIME_PYTHON" "$user_tool" "$action" --label "$CAPE_MACHINE_LABEL" --deployment-id "$DEPLOYMENT_ID" --guard-file "$user_guard"; then
        rc=0
      else
        rc=$?
      fi
      rm -f "$user_guard" "$user_guard.pending" "$user_tool"
      rmdir "$user_dir" 2>/dev/null || true
      if [[ "$rc" -eq 0 ]]; then
        rm -f "$CAPE_MAINTENANCE_GUARD_FILE"
      else
        warn "CAPE maintenance release was incomplete; preserving recovery guard $CAPE_MAINTENANCE_GUARD_FILE"
      fi
      return "$rc"
    elif [[ "$action" == verify ]]; then
      install -m 0600 -o "$CAPE_SERVICE_USER" "$CAPE_MAINTENANCE_GUARD_FILE" "$user_guard" 2>/dev/null || {
        rm -f "$user_tool"
        fail "Could not stage CAPE maintenance guard for verification"
        return 1
      }
      local rc
      if runuser -u "$CAPE_SERVICE_USER" -- env PYTHONPATH="$CAPE_ROOT" "$CAPE_RUNTIME_PYTHON" "$user_tool" "$action" --label "$CAPE_MACHINE_LABEL" --deployment-id "$DEPLOYMENT_ID" --guard-file "$user_guard"; then
        rc=0
      else
        rc=$?
      fi
      rm -f "$user_guard" "$user_guard.pending" "$user_tool"
      rmdir "$user_dir" 2>/dev/null || true
      return "$rc"
    else
      local rc
      if runuser -u "$CAPE_SERVICE_USER" -- env PYTHONPATH="$CAPE_ROOT" "$CAPE_RUNTIME_PYTHON" "$user_tool" "$action" --label "$CAPE_MACHINE_LABEL" --deployment-id "$DEPLOYMENT_ID" --guard-file "$user_guard"; then
        rc=0
      else
        rc=$?
      fi
      rm -f "$user_tool"
      rmdir "$user_dir" 2>/dev/null || true
      return "$rc"
    fi
  fi
}

cape_wait_and_acquire_maintenance() {
  local timeout="${1:-3600}" elapsed=0 rc
  local log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-cape-maintenance.log"
  : >"$log"
  chmod 0600 "$log"
  while ((elapsed < timeout)); do
    printf '=== acquire attempt at %s ===\n' "$(date -Is)" >>"$log"
    if cape_maintenance_tool acquire >>"$log" 2>&1; then
      rc=0
    else
      rc=$?
    fi
    printf 'exit_code=%s\n' "$rc" >>"$log"
    if [[ "$rc" -eq 0 ]]; then
      state_record_resource cape-maintenance all-machines acquired yes "$CAPE_MAINTENANCE_GUARD_FILE log=$log"
      pass "CAPE machine scheduling paused at a task-safe point"
      return 0
    fi
    if [[ "$rc" -ne 20 ]]; then
      fail "CAPE maintenance acquisition failed; diagnostic log: $log"
      return "$rc"
    fi
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

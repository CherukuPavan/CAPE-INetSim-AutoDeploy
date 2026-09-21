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
    (cd "$CAPE_ROOT" && env PYTHONPATH="$CAPE_ROOT" "$CAPE_RUNTIME_PYTHON" "$AUTODEPLOY_ROOT/tools/cape_maintenance.py" "$action" --label "$CAPE_MACHINE_LABEL" --guard-file "$CAPE_MAINTENANCE_GUARD_FILE")
  else
    # The guard directory/file is root-owned, so the helper writes through a
    # temporary CAPE-user path for acquire and root moves it into place.
    local user_guard="/tmp/cape-inetsim-guard-$$.json"
    if [[ "$action" == acquire ]]; then
      runuser -u "$CAPE_SERVICE_USER" -- env PYTHONPATH="$CAPE_ROOT" "$CAPE_RUNTIME_PYTHON" "$AUTODEPLOY_ROOT/tools/cape_maintenance.py" "$action" --label "$CAPE_MACHINE_LABEL" --guard-file "$user_guard"
      if ! install -m 0600 -o root -g root "$user_guard" "$CAPE_MAINTENANCE_GUARD_FILE"; then
        # The DB locks are already committed. Immediately release them using
        # the CAPE-user guard rather than leaving machines orphan-locked.
        runuser -u "$CAPE_SERVICE_USER" -- env PYTHONPATH="$CAPE_ROOT" "$CAPE_RUNTIME_PYTHON" "$AUTODEPLOY_ROOT/tools/cape_maintenance.py" release --label "$CAPE_MACHINE_LABEL" --guard-file "$user_guard" >/dev/null 2>&1 || true
        rm -f "$user_guard"
        fail "Could not persist CAPE maintenance guard; locks were released"
        return 1
      fi
      rm -f "$user_guard"
    elif [[ "$action" == release ]]; then
      local copy="/tmp/cape-inetsim-guard-$$.json"
      install -m 0600 -o "$CAPE_SERVICE_USER" "$CAPE_MAINTENANCE_GUARD_FILE" "$copy" 2>/dev/null || true
      set +e
      runuser -u "$CAPE_SERVICE_USER" -- env PYTHONPATH="$CAPE_ROOT" "$CAPE_RUNTIME_PYTHON" "$AUTODEPLOY_ROOT/tools/cape_maintenance.py" "$action" --label "$CAPE_MACHINE_LABEL" --guard-file "$copy"
      local rc=$?
      set -e
      rm -f "$copy"
      if [[ "$rc" -eq 0 ]]; then
        rm -f "$CAPE_MAINTENANCE_GUARD_FILE"
      else
        warn "CAPE maintenance release was incomplete; preserving recovery guard $CAPE_MAINTENANCE_GUARD_FILE"
      fi
      return "$rc"
    else
      runuser -u "$CAPE_SERVICE_USER" -- env PYTHONPATH="$CAPE_ROOT" "$CAPE_RUNTIME_PYTHON" "$AUTODEPLOY_ROOT/tools/cape_maintenance.py" "$action" --label "$CAPE_MACHINE_LABEL" --guard-file "$user_guard"
    fi
  fi
}

cape_wait_and_acquire_maintenance() {
  local timeout="${1:-3600}" elapsed=0 rc
  while ((elapsed < timeout)); do
    set +e
    cape_maintenance_tool acquire
    rc=$?
    set -e
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
  set +e
  cape_maintenance_tool release
  local rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    state_record_resource cape-maintenance all-machines released yes ""
    return 0
  fi
  state_record_resource cape-maintenance all-machines release-incomplete yes "rc=$rc guard=$CAPE_MAINTENANCE_GUARD_FILE"
  fail "CAPE maintenance release incomplete; guard preserved for safe recovery"
  return "$rc"
}

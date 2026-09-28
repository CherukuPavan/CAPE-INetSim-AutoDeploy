#!/usr/bin/env bash

# Runtime/service discovery for heterogeneous CAPE hosts.
# No CAPE path, username, Python environment, service name, or rooter socket is assumed.

AD_HOST_PYTHON=""

discover_host_python() {
  local p
  for p in "$(command -v python3 2>/dev/null || true)" "$(command -v python 2>/dev/null || true)" /usr/bin/python3 /usr/local/bin/python3; do
    [[ -n "$p" && -x "$p" ]] || continue
    "$p" -c 'import json,configparser,ipaddress,xml.etree.ElementTree' >/dev/null 2>&1 || continue
    AD_HOST_PYTHON="$(readlink -f "$p" 2>/dev/null || printf '%s' "$p")"
    export AD_HOST_PYTHON
    return 0
  done
  add_error "No usable host Python interpreter was found"
  return 0
}

ad_python() {
  [[ -n "${AD_HOST_PYTHON:-}" ]] || discover_host_python
  [[ -x "${AD_HOST_PYTHON:-}" ]] || { fail "Host Python is unavailable"; return 1; }
  "$AD_HOST_PYTHON" "$@"
}

systemd_service_inventory() {
  systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null |
    awk '{print $1}' | sed '/^$/d' | sort -u
}

service_execstart_text() {
  systemctl show "$1" -p ExecStart --value 2>/dev/null || true
}

service_workdir_text() {
  systemctl show "$1" -p WorkingDirectory --value 2>/dev/null || true
}

discover_service_by_role() {
  local role="$1" unit exec wd score best="" best_score=0
  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    exec="$(service_execstart_text "$unit")"
    wd="$(service_workdir_text "$unit")"
    score=0
    case "$role" in
      scheduler)
        [[ "$unit" == cape.service ]] && score=$((score+40))
        [[ "$exec" =~ (cuckoo\.py|cape\.py|python[^[:space:]]*[[:space:]].*cuckoo) ]] && score=$((score+60))
        ;;
      processor)
        [[ "$unit" == cape-processor.service ]] && score=$((score+40))
        [[ "$exec" =~ (process\.py|processor) ]] && score=$((score+60))
        ;;
      web)
        [[ "$unit" == cape-web.service ]] && score=$((score+40))
        [[ "$exec" =~ (manage\.py|gunicorn|uwsgi|web) ]] && score=$((score+45))
        ;;
      rooter)
        [[ "$unit" == cape-rooter.service ]] && score=$((score+40))
        [[ "$exec" =~ (rooter\.py|cape-rooter) ]] && score=$((score+70))
        ;;
    esac
    if [[ -n "${CAPE_ROOT:-}" ]]; then
      [[ "$wd" == "$CAPE_ROOT"* || "$exec" == *"$CAPE_ROOT"* ]] && score=$((score+20))
    fi
    if ((score > best_score)); then best="$unit"; best_score="$score"; fi
  done < <(systemd_service_inventory)
  [[ -n "$best" ]] && printf '%s\n' "$best"
}

discover_cape_service_roles() {
  CAPE_SCHEDULER_SERVICE="$(discover_service_by_role scheduler || true)"
  CAPE_PROCESSOR_SERVICE="$(discover_service_by_role processor || true)"
  CAPE_WEB_SERVICE="$(discover_service_by_role web || true)"
  CAPE_ROOTER_SERVICE="$(discover_service_by_role rooter || true)"
  export CAPE_SCHEDULER_SERVICE CAPE_PROCESSOR_SERVICE CAPE_WEB_SERVICE CAPE_ROOTER_SERVICE
}

service_main_python() {
  local svc="$1" pid exe
  [[ -n "$svc" ]] || return 1
  pid="$(systemctl show "$svc" -p MainPID --value 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]]; then
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    [[ -x "$exe" ]] && { printf '%s\n' "$exe"; return 0; }
  fi
  return 1
}

cape_python_candidates() {
  local svc p exec token
  for svc in "${CAPE_SCHEDULER_SERVICE:-}" "${CAPE_PROCESSOR_SERVICE:-}" "${CAPE_WEB_SERVICE:-}"; do
    service_main_python "$svc" 2>/dev/null || true
    exec="$(service_execstart_text "$svc")"
    for token in $exec; do
      token="${token#\{}"; token="${token%\}}"; token="${token#\"}"; token="${token%\"}"
      if [[ "$token" == /*python* && -x "$token" ]]; then printf '%s\n' "$token"; fi
    done
  done
  [[ -n "${CAPE_ROOT:-}" && -x "$CAPE_ROOT/.venv/bin/python" ]] && printf '%s\n' "$CAPE_ROOT/.venv/bin/python"
  [[ -n "${CAPE_ROOT:-}" && -x "$CAPE_ROOT/venv/bin/python" ]] && printf '%s\n' "$CAPE_ROOT/venv/bin/python"
  if [[ -n "${CAPE_ROOT:-}" ]] && command -v poetry >/dev/null 2>&1; then
    p="$(cd "$CAPE_ROOT" && poetry env info -p 2>/dev/null || true)"
    [[ -n "$p" && -x "$p/bin/python" ]] && printf '%s\n' "$p/bin/python"
  fi
  [[ -n "${AD_HOST_PYTHON:-}" ]] && printf '%s\n' "$AD_HOST_PYTHON"
}

cape_python_is_valid() {
  local py="$1"
  [[ -x "$py" && -n "${CAPE_ROOT:-}" ]] || return 1
  (cd "$CAPE_ROOT" && "$py" - <<'PY'
import importlib
for name in ("django", "lib.cuckoo.common.config", "lib.cuckoo.core.rooter"):
    importlib.import_module(name)
print("ok")
PY
  ) >/dev/null 2>&1
}

discover_cape_python() {
  CAPE_PYTHON=""
  local py
  while IFS= read -r py; do
    [[ -n "$py" ]] || continue
    if cape_python_is_valid "$py"; then
      CAPE_PYTHON="$(readlink -f "$py" 2>/dev/null || printf '%s' "$py")"
      break
    fi
  done < <(cape_python_candidates | awk '!seen[$0]++')
  [[ -n "$CAPE_PYTHON" ]] || add_error "No CAPE Python interpreter could import django and CAPE modules"
  export CAPE_PYTHON
}

discover_runtime_environment() {
  discover_host_python
  # First pass permits service names to contribute to CAPE-root discovery.
  discover_cape_service_roles
}

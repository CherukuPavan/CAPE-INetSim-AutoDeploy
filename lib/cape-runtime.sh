#!/usr/bin/env bash

cape_run_as_user() {
  local service_user="$1"
  shift
  (
    cd "$CAPE_ROOT" || exit 1
    if [[ "$service_user" == "$(id -un)" ]]; then
      env -u PYTHONHOME PYTHONPATH="$CAPE_ROOT" PYTHONDONTWRITEBYTECODE=1 "$@"
    else
      runuser -u "$service_user" -- env -u PYTHONHOME \
        PYTHONPATH="$CAPE_ROOT" PYTHONDONTWRITEBYTECODE=1 "$@"
    fi
  )
}

cape_service_python() {
  local unit="${1:-cape.service}" pid candidate launcher service_user env_dir
  if [[ "$unit" == cape.service && -n "${CAPE_RUNTIME_PYTHON:-}" ]]; then
    [[ "$CAPE_RUNTIME_PYTHON" == /* && -x "$CAPE_RUNTIME_PYTHON" ]] || return 1
    printf '%s\n' "$CAPE_RUNTIME_PYTHON"
    return 0
  fi

  pid="$(systemctl show "$unit" -p MainPID --value 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]]; then
    # /proc/PID/exe resolves a venv symlink to the base Python, discarding its
    # packages. Read NUL-delimited argv instead; do not split paths on spaces.
    candidate="$(python3 - "$pid" <<'PY'
import os,re,shutil,sys
from pathlib import Path
try:
    proc=Path('/proc')/sys.argv[1]
    argv=proc.joinpath('cmdline').read_bytes().split(b'\0')
    exe=os.fsdecode(argv[0])
    if not re.fullmatch(r'python(?:[0-9]+(?:\.[0-9]+)*)?',os.path.basename(exe)):
        raise ValueError('service is using a launcher')
    if not os.path.isabs(exe):
        cwd=os.readlink(proc/'cwd')
        if '/' in exe:
            exe=os.path.abspath(os.path.join(cwd,exe))
        else:
            env=dict(x.split(b'=',1) for x in proc.joinpath('environ').read_bytes().split(b'\0') if b'=' in x)
            path=os.fsdecode(env.get(b'PATH',b''))
            # Resolve only against the service PATH, never the installer's PATH.
            dirs=[p if os.path.isabs(p) else os.path.join(cwd,p) for p in path.split(':')]
            exe=shutil.which(exe,path=os.pathsep.join(dirs)) or ''
    if exe and os.access(exe,os.X_OK):
        print(exe)
except (OSError,ValueError):
    pass
PY
)"
    if [[ -n "$candidate" ]]; then printf '%s\n' "$candidate"; return 0; fi
  fi

  # Also works after the scheduler stops for configuration handoff. Query the
  # configured Poetry project as its service account; this does not install or
  # create an environment. Never eval systemd's command text.
  launcher="$(systemctl show "$unit" -p ExecStart --value 2>/dev/null | python3 -c '
import re,shlex,sys
s=sys.stdin.read()
m=re.search(r"argv\[\]=(.*?)(?:\s*;\s*ignore_errors=|\s*;\s*start_time=|\s*\}$)",s)
if m:
    try:
        args=shlex.split(m.group(1))
        if args: print(args[0])
    except ValueError: pass
' || true)"
  service_user="$(systemctl show "$unit" -p User --value 2>/dev/null || true)"
  service_user="${service_user:-root}"
  if [[ "$launcher" == /* && -x "$launcher" ]]; then
    case "${launcher##*/}" in
      python|python[0-9]|python[0-9].[0-9]|python[0-9].[0-9][0-9])
        printf '%s\n' "$launcher"; return 0 ;;
      poetry)
        candidate="$(cape_run_as_user "$service_user" timeout 20 "$launcher" env info --executable 2>/dev/null || true)"
        if [[ "$candidate" == /* && -x "$candidate" ]]; then
          printf '%s\n' "$candidate"; return 0
        fi
        env_dir="$(cape_run_as_user "$service_user" timeout 20 "$launcher" env info --path 2>/dev/null || true)"
        if [[ "$env_dir" == /* && -x "$env_dir/bin/python" ]]; then
          printf '%s\n' "$env_dir/bin/python"; return 0
        fi
        ;;
    esac
  fi
  if [[ -x "$CAPE_ROOT/.venv/bin/python" ]]; then
    printf '%s\n' "$CAPE_ROOT/.venv/bin/python"
    return 0
  fi
  printf '[FAIL] Could not identify the Python environment for %s\n' "$unit" >&2
  return 1
}

cape_runtime_python() {
  cape_service_python cape.service
}

discover_cape_runtime() {
  CAPE_SERVICE_USER="$(systemctl show cape.service -p User --value 2>/dev/null || true)"
  CAPE_SERVICE_USER="${CAPE_SERVICE_USER:-root}"
  CAPE_RUNTIME_PYTHON="$(cape_runtime_python)" || return 1
  [[ -x "$CAPE_RUNTIME_PYTHON" ]]
}

#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/qga.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
COUNT="$TMP/count"
printf '0\n' >"$COUNT"

sleep(){ :; }

virsh() {
  [[ "$1" == qemu-agent-command ]]
  local payload="$3"
  if [[ "$payload" == *'"guest-exec"'* ]]; then
    printf '%s\n' '{"return":{"pid":42}}'
    return 0
  fi
  if [[ "$payload" == *'"guest-exec-status"'* ]]; then
    local n
    n="$(cat "$COUNT")"
    n=$((n+1))
    printf '%s\n' "$n" >"$COUNT"
    if ((n <= 3)); then
      echo 'temporary QGA unavailable' >&2
      return 1
    fi
    printf '%s\n' '{"return":{"exited":true,"exitcode":0,"out-data":"T0sK"}}'
    return 0
  fi
  return 1
}

out="$(qga_exec_wait vm /bin/true)"
[[ "$out" == "OK" ]]
[[ "$(cat "$COUNT")" -eq 4 ]]

# Fifteen consecutive status failures must still stop safely.
printf '0\n' >"$COUNT"
virsh() {
  [[ "$1" == qemu-agent-command ]]
  local payload="$3"
  if [[ "$payload" == *'"guest-exec"'* ]]; then
    printf '%s\n' '{"return":{"pid":43}}'
    return 0
  fi
  echo 'temporary QGA unavailable' >&2
  return 1
}
set +e
qga_exec_wait vm /bin/true >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 125 ]]

echo '[PASS] QGA execution tolerates transient status polling loss and boundedly safe-stops'

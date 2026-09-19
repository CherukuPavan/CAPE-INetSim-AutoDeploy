#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="$(hostname -s 2>/dev/null || hostname)"
TS="$(date +%Y%m%d_%H%M%S)"
OUT="$HOME/${HOST}_AUTODEPLOY_PLAN_${TS}"
ARCHIVE="${OUT}.tar.gz"

mkdir -p "$OUT"

{
  echo "CAPE-INetSim-AutoDeploy read-only validation"
  echo "host=$HOST"
  echo "time=$(date -Is)"
  echo
  git -C "$ROOT" rev-parse HEAD 2>/dev/null || true
} >"$OUT/meta.txt"

bash "$ROOT/tests/syntax.sh" >"$OUT/syntax.txt" 2>&1
bash "$ROOT/tests/universal_logic.sh" >"$OUT/universal_logic.txt" 2>&1

set +e
sudo "$ROOT/install" --plan >"$OUT/plan.txt" 2>&1
PLAN_RC=$?
set -e
printf '%s\n' "$PLAN_RC" >"$OUT/plan_exit_code.txt"

tar -czf "$ARCHIVE" -C "$HOME" "$(basename "$OUT")"

echo
echo "============================================================"
echo "READ-ONLY AUTODEPLOY PLAN COLLECTION COMPLETE"
echo "============================================================"
echo "Archive:"
echo "$ARCHIVE"
echo
echo "Nothing in CAPE, libvirt, Windows, snapshots, networks, or services was changed."
echo "Upload the .tar.gz file."

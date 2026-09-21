#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for f in "$ROOT/install" "$ROOT"/lib/*.sh "$ROOT"/bin/* "$ROOT"/tests/*.sh; do
  bash -n "$f"
done

[[ -x "$ROOT/install" ]] || { echo "[FAIL] install entrypoint is not executable" >&2; exit 1; }
for f in "$ROOT"/bin/cape-inetsim-*; do
  [[ -x "$f" ]] || { echo "[FAIL] operator entrypoint is not executable: $f" >&2; exit 1; }
done
echo "[PASS] bash syntax"

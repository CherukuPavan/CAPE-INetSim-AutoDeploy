#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for f in "$ROOT/install" "$ROOT"/lib/*.sh "$ROOT"/tests/*.sh; do bash -n "$f"; done
echo "[PASS] bash syntax"

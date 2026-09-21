#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT/bin/cape-inetsim-collect" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()
assert r"([A-Za-z][A-Za-z0-9+.-]*://)[^/@\s]+@" in s
assert r"urlcred.sub(r'\1***REDACTED***@'" in s
assert r"(https?://)[^/@\s]+@" not in s
PY

grep -Fq -- '--collect) MODE=collect' "$ROOT/install"
grep -Fq 'exec bash "$AUTODEPLOY_ROOT/bin/cape-inetsim-collect"' "$ROOT/install"
grep -Fq 'OUTPUT_USER="${SUDO_USER:-$(id -un)}"' "$ROOT/bin/cape-inetsim-collect"

echo '[PASS] supported read-only collector redacts URI credentials and is exposed as --collect'

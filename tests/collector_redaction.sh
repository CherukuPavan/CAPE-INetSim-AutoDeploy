#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT/tests/collect-deep-inventory.sh" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()
assert r"([A-Za-z][A-Za-z0-9+.-]*://)[^/@\s]+@" in s
assert r"urlcred.sub(r'\1***REDACTED***@'" in s
assert r"(https?://)[^/@\s]+@" not in s
PY

echo '[PASS] deep-inventory collector redacts credentials from arbitrary URI schemes'

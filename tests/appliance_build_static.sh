#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -m json.tool "$ROOT/appliance/build/base-image.json" >/dev/null
python3 -m py_compile "$ROOT/appliance/build/render-manifest.py"
grep -q 'release-20260801' "$ROOT/appliance/build/base-image.json"
grep -q '0533b0655c32e68b31d792ecd6ccfca95abdbc536c4446874fe0513bd4140ffe' "$ROOT/appliance/build/base-image.json"
grep -q 'virt-sysprep' "$ROOT/appliance/build/build.sh"
grep -q -- '--management-mac' "$ROOT/appliance/guest-configure.sh"
! grep -q '192\.168\.200\.' "$ROOT/appliance/guest-configure.sh"
echo '[PASS] pinned/generalized appliance build pipeline'

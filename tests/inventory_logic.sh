#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/autodeploy-inventory.json"

export AD_STATE_ROOT="$TMP/state"
export CAPE_ROOT="$TMP/arbitrary-cape"
export CAPE_ROOT_SOURCE=fixture
export CAPE_COMMIT=deadbeef
export CAPE_BRANCH=fixture
export CAPE_DIRTY=no
export CAPE_DB_BACKEND=postgresql
export CAPE_TARGETS_JSON='[{"section":"sandboxA","domain":"vm-alpha","ip":"10.10.10.20"}]'
export AD_HOST_PYTHON="$(command -v python3)"
export CAPE_RUNTIME_PYTHON="$AD_HOST_PYTHON"
mkdir -p "$CAPE_ROOT"

"$AD_HOST_PYTHON" "$ROOT/tools/inventory.py" --output "$OUT" --decision fresh --decision-reason fixture >/dev/null
"$AD_HOST_PYTHON" - "$OUT" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["schema"]==1
for key in ("host","cape","virtualization","network","firewall","python_environments","autodeploy","decision"):
    assert key in d,key
h=d["host"]
for key in ("os_release","architecture","kernel","cpu","memory","disk","kvm","libvirt"):
    assert key in h,key
assert d["decision"]["class"]=="fresh"
assert d["cape"]["targets_json"][0]["domain"]=="vm-alpha"
PY
[[ "$(stat -c %a "$OUT")" == 600 ]]

echo "[PASS] autodeploy-inventory.json contains required production inventory sections"

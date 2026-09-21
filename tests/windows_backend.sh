#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/windows-cape-agent.sh"

mock='{"message":"CAPE Agent!","version":"0.22","features":["execute","largefile"],"is_user_admin":true}'
python3 - "$mock" <<'PY'
import json,sys
d=json.loads(sys.argv[1])
assert d['is_user_admin'] is True
assert 'execute' in d['features']
assert 'largefile' in d['features']
PY

grep -q 'Get-NetAdapter' "$ROOT/windows/configure-inetsim.ps1"
grep -q "DestinationPrefix '0.0.0.0/0'" "$ROOT/windows/configure-inetsim.ps1"
grep -q 'Test-NetConnection' "$ROOT/windows/configure-inetsim.ps1"
grep -q 'Resolve-DnsName' "$ROOT/windows/configure-inetsim.ps1"

echo '[PASS] CAPE-agent backend and Windows safety script present'

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
grep -Fq -- 'qemu-img info --force-share --backing-chain' "$ROOT/bin/cape-inetsim-collect"
grep -Fq 'libvirt/nwfilter_runtime' "$ROOT/bin/cape-inetsim-collect"
grep -Fq 'virsh nwfilter-binding-list' "$ROOT/bin/cape-inetsim-collect"
grep -Fq 'virtnwfilterd.socket' "$ROOT/bin/cape-inetsim-collect"


TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/secrets.txt" <<'EOF'
DATABASE_URL=postgresql://cape:supersecret@example.invalid/cape
password=hunter2
Authorization: Bearer abcdefghijklmnopqrstuvwxyz
command --token github_pat_012345678901234567890123456789
aws=AKIAABCDEFGHIJKLMNOP
-----BEGIN PRIVATE KEY-----
secret-private-key-material
-----END PRIVATE KEY-----
EOF
python3 "$ROOT/tools/redact_inventory.py" "$TMP" >/dev/null
! grep -Fq 'supersecret' "$TMP/secrets.txt"
! grep -Fq 'hunter2' "$TMP/secrets.txt"
! grep -Fq 'abcdefghijklmnopqrstuvwxyz' "$TMP/secrets.txt"
! grep -Fq 'github_pat_012345678901234567890123456789' "$TMP/secrets.txt"
! grep -Fq 'AKIAABCDEFGHIJKLMNOP' "$TMP/secrets.txt"
! grep -Fq 'secret-private-key-material' "$TMP/secrets.txt"
grep -Fq '***REDACTED***' "$TMP/secrets.txt"
grep -Fq 'redact_inventory.py' "$ROOT/bin/cape-inetsim-collect"

echo '[PASS] supported read-only collector redacts bundle-wide credentials and is exposed as --collect'

grep -Fq "'*inetsim-host-verify.log'" "$ROOT/bin/cape-inetsim-collect"
grep -Fq "'*cape-maintenance.log'" "$ROOT/bin/cape-inetsim-collect"
grep -Fq "'*cape-resultserver-readiness.log'" "$ROOT/bin/cape-inetsim-collect"
grep -Fq "'*windows-isolated-control-stage.json'" "$ROOT/bin/cape-inetsim-collect"
grep -Fq "'*cape-agent-execpy.txt'" "$ROOT/bin/cape-inetsim-collect"
grep -Fq "'*progress.txt'" "$ROOT/bin/cape-inetsim-collect"
grep -Fq "'*windows-finalize*.json'" "$ROOT/bin/cape-inetsim-collect"
grep -Fq 'extension-v*' "$ROOT/bin/cape-inetsim-collect"
grep -Fq 'RUNTIME-SHA256SUMS' "$ROOT/bin/cape-inetsim-collect"
grep -Fq 'cape-inetsim-network-diagnose' "$ROOT/bin/cape-inetsim-network-diagnose"
grep -Fq 'redact_inventory.py' "$ROOT/bin/cape-inetsim-network-diagnose"
grep -Fq 'config.redacted.txt' "$ROOT/bin/cape-inetsim-collect"
grep -Fq "'*poweroff*.json'" "$ROOT/bin/cape-inetsim-collect"
grep -Fq 'for name in machines:' "$ROOT/bin/cape-inetsim-collect"
grep -Fq 'machine=$label target=$ip port=$p' "$ROOT/bin/cape-inetsim-collect"
! grep -Fq 'tail -1 | cut -d= -f2-' "$ROOT/bin/cape-inetsim-collect"

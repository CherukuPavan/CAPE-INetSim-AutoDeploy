#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 -m json.tool "$ROOT/appliance/build/base-image.json" >/dev/null
python3 -m py_compile   "$ROOT/appliance/build/render-manifest.py"   "$ROOT/appliance/build/render-cloud-init.py"
dash -n "$ROOT/appliance/image-rootfs-prepare.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 "$ROOT/appliance/build/render-cloud-init.py"   --guest-configure "$ROOT/appliance/guest-configure.sh"   --prepare "$ROOT/appliance/image-rootfs-prepare.sh"   --output "$TMP/user-data"

grep -Fxq '#cloud-config' "$TMP/user-data"
grep -q 'cape-inetsim-image-rootfs-prepare' "$TMP/user-data"
grep -q 'cape-inetsim-build-wrapper' "$TMP/user-data"

python3 - "$TMP/user-data" <<'PY'
import base64,re,sys
s=open(sys.argv[1],encoding="utf-8").read()
m=re.search(r'path: /root/cape-inetsim-build-wrapper.*?content: ([A-Za-z0-9+/=]+)',s,re.S)
assert m, "build wrapper payload missing"
decoded=base64.b64decode(m.group(1))
assert b"poweroff -f" in decoded
assert b"cape-inetsim-build-ok" in decoded
PY

grep -q 'release-20260801' "$ROOT/appliance/build/base-image.json"
grep -q '0533b0655c32e68b31d792ecd6ccfca95abdbc536c4446874fe0513bd4140ffe' "$ROOT/appliance/build/base-image.json"
grep -q 'virt-sysprep' "$ROOT/appliance/build/build.sh"
grep -q 'virt-resize --expand /dev/sda1' "$ROOT/appliance/build/build.sh"
grep -q 'cloud-localds' "$ROOT/appliance/build/build.sh"
grep -q 'qemu-system-x86_64' "$ROOT/appliance/build/build.sh"
grep -q 'render-cloud-init.py' "$ROOT/appliance/build/build.sh"
grep -q 'cape-inetsim-build-ok' "$ROOT/appliance/build/build.sh"
grep -q 'virt-df' "$ROOT/appliance/build/build.sh"
grep -q 'APPLIANCE_BASE_CACHE' "$ROOT/appliance/build/build.sh"
grep -q 'using verified cached Ubuntu base release' "$ROOT/appliance/build/build.sh"
grep -q -- '--management-mac' "$ROOT/appliance/guest-configure.sh"
! grep -q '192\.168\.200\.' "$ROOT/appliance/guest-configure.sh"

echo '[PASS] pinned/generalized appliance build pipeline'

#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 -m json.tool "$ROOT/appliance/build/base-image.json" >/dev/null
python3 -m py_compile \
  "$ROOT/appliance/build/render-manifest.py" \
  "$ROOT/appliance/build/render-cloud-init.py"
dash -n "$ROOT/appliance/image-rootfs-prepare.sh"
bash -n "$ROOT/appliance/build/verify-artifact.sh"
bash -n "$ROOT/appliance/build/runtime-smoke-test.sh"
bash -n "$ROOT/appliance/gui-enable.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 "$ROOT/appliance/build/render-cloud-init.py" \
  --guest-configure "$ROOT/appliance/guest-configure.sh" \
  --prepare "$ROOT/appliance/image-rootfs-prepare.sh" \
  --gui-enable "$ROOT/appliance/gui-enable.sh" \
  --output "$TMP/user-data"

printf 'raw appliance test bytes\n' >"$TMP/test.qcow2"
gzip -c "$TMP/test.qcow2" >"$TMP/test.qcow2.gz"
python3 "$ROOT/appliance/build/render-manifest.py" \
  --artifact "$TMP/test.qcow2" \
  --transport-artifact "$TMP/test.qcow2.gz" \
  --url "https://example.invalid/test.qcow2.gz" \
  --output "$TMP/manifest.json"
python3 - "$TMP/manifest.json" "$TMP/test.qcow2" "$TMP/test.qcow2.gz" <<'PY'
import hashlib,json,sys
m=json.load(open(sys.argv[1]))
def h(path):
    x=hashlib.sha256()
    x.update(open(path,"rb").read())
    return x.hexdigest()
assert m["status"]=="published"
assert m["artifact_name"]=="test.qcow2"
assert m["sha256"]==h(sys.argv[2])
assert m["artifact_url"]=="https://example.invalid/test.qcow2.gz"
assert m["transport"]["compression"]=="gzip"
assert m["transport"]["artifact_name"]=="test.qcow2.gz"
assert m["transport"]["sha256"]==h(sys.argv[3])
PY

grep -Fxq '#cloud-config' "$TMP/user-data"
grep -q 'cape-inetsim-image-rootfs-prepare' "$TMP/user-data"
grep -q 'cape-inetsim-build-wrapper' "$TMP/user-data"
grep -q 'cape-inetsim-gui-enable' "$TMP/user-data"
grep -q '^growpart:' "$TMP/user-data"
grep -q '^resize_rootfs: true$' "$TMP/user-data"

python3 - "$TMP/user-data" <<'PY'
import base64,re,sys
s=open(sys.argv[1],encoding="utf-8").read()
m=re.search(r'path: /root/cape-inetsim-build-wrapper.*?content: ([A-Za-z0-9+/=]+)',s,re.S)
assert m, "build wrapper payload missing"
decoded=base64.b64decode(m.group(1))
assert b"poweroff -f" in decoded
assert b"cape-inetsim-build-ok" in decoded
assert b"/dev/console" in decoded
assert b"PIPESTATUS" in decoded
PY

grep -q 'release-20260801' "$ROOT/appliance/build/base-image.json"
grep -q '0533b0655c32e68b31d792ecd6ccfca95abdbc536c4446874fe0513bd4140ffe' "$ROOT/appliance/build/base-image.json"

grep -q 'guestfish --rw' "$ROOT/appliance/build/build.sh"
! grep -q 'virt-customize -a' "$ROOT/appliance/build/build.sh"
grep -Fq ': >/etc/machine-id' "$ROOT/appliance/image-rootfs-prepare.sh"
grep -q 'ssh_host_.*_key' "$ROOT/appliance/image-rootfs-prepare.sh"
grep -Fq "cape-inetsim-appliance' >/etc/hostname" "$ROOT/appliance/image-rootfs-prepare.sh"
grep -q 'qemu-img convert -p -O qcow2' "$ROOT/appliance/build/build.sh"
grep -Fq 'qemu-img resize "$OUT.part" 20G' "$ROOT/appliance/build/build.sh"
! grep -q 'virt-resize --expand' "$ROOT/appliance/build/build.sh"
grep -q 'cloud-localds' "$ROOT/appliance/build/build.sh"
grep -q 'qemu-system-x86_64' "$ROOT/appliance/build/build.sh"
grep -q 'type=q35,accel=kvm' "$ROOT/appliance/build/build.sh"
grep -q -- '-nographic' "$ROOT/appliance/build/build.sh"
grep -q 'APPLIANCE_DIAG_DIR' "$ROOT/appliance/build/build.sh"
grep -q 'cloud-init-output.log' "$ROOT/appliance/build/build.sh"
grep -q 'render-cloud-init.py' "$ROOT/appliance/build/build.sh"
grep -q 'cape-inetsim-build-ok' "$ROOT/appliance/build/build.sh"
grep -q 'virt-df' "$ROOT/appliance/build/build.sh"
grep -q 'APPLIANCE_BASE_CACHE' "$ROOT/appliance/build/build.sh"
grep -q 'using verified cached Ubuntu base release' "$ROOT/appliance/build/build.sh"

grep -q 'Acquire::http::Timeout=30' "$ROOT/appliance/image-rootfs-prepare.sh"
grep -q 'timeout 600 apt-get' "$ROOT/appliance/image-rootfs-prepare.sh"
grep -Fq 'cape-inetsim-gui-enable' "$ROOT/appliance/image-rootfs-prepare.sh"
grep -Fq 'xfce4' "$ROOT/appliance/gui-enable.sh"
grep -Fq 'lightdm' "$ROOT/appliance/gui-enable.sh"
grep -Fq 'cape-inetsim-gui-v2' "$ROOT/appliance/gui-enable.sh"
grep -Fq 'autologin-user=' "$ROOT/appliance/gui-enable.sh"
grep -Fq 'autologin-session=xfce' "$ROOT/appliance/gui-enable.sh"
grep -Fq 'greeter-show-manual-login=false' "$ROOT/appliance/gui-enable.sh"
grep -Fq 'passwd -l' "$ROOT/appliance/gui-enable.sh"
grep -Fq 'xserver-xorg-video-qxl' "$ROOT/appliance/gui-enable.sh"

grep -q 'full-backing-filename' "$ROOT/appliance/build/verify-artifact.sh"
grep -q 'persistent machine-id' "$ROOT/appliance/build/verify-artifact.sh"
grep -q 'persistent SSH host private keys' "$ROOT/appliance/build/verify-artifact.sh"
grep -q 'cloud-init instance state' "$ROOT/appliance/build/verify-artifact.sh"
grep -q 'deployment-owned netplan state' "$ROOT/appliance/build/verify-artifact.sh"
grep -q 'temporary build DNS state' "$ROOT/appliance/build/verify-artifact.sh"
grep -q 'persistent static/default network configuration' "$ROOT/appliance/build/verify-artifact.sh"
grep -q 'appliance_verify.outcome' "$ROOT/.github/workflows/appliance-build.yml"
grep -q 'appliance_runtime_smoke.outcome' "$ROOT/.github/workflows/appliance-build.yml"
grep -q 'runtime-smoke-test.sh' "$ROOT/.github/workflows/appliance-build.yml"
grep -q 'cape-inetsim-runtime-smoke-ok' "$ROOT/appliance/build/runtime-smoke-test.sh"
grep -Fq -- '-vga qxl' "$ROOT/appliance/build/runtime-smoke-test.sh"
grep -Fq 'pgrep -u capeinetsim' "$ROOT/appliance/build/runtime-smoke-test.sh"
grep -Fq 'passwordless XFCE/QXL autologin' "$ROOT/appliance/build/runtime-smoke-test.sh"
grep -q -- '--transport-artifact' "$ROOT/appliance/build/render-manifest.py"
grep -q '"compression":"gzip"' "$ROOT/appliance/build/render-manifest.py"

grep -q -- '--management-mac' "$ROOT/appliance/guest-configure.sh"
grep -Fq 'expected at most one management default route' "$ROOT/appliance/guest-configure.sh"
grep -Fq '[[ "$DEFAULTS" -le 1 ]]' "$ROOT/appliance/guest-configure.sh"
! grep -Fq 'expected exactly one management default route' "$ROOT/appliance/guest-configure.sh"
! grep -q '192\.168\.200\.' "$ROOT/appliance/guest-configure.sh"
grep -Fq 'sysctl -w net.ipv4.ip_forward=0' "$ROOT/appliance/guest-configure.sh"
! grep -Fq 'sysctl --system' "$ROOT/appliance/guest-configure.sh"

echo '[PASS] pinned/generalized appliance build pipeline'

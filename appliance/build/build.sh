#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_MANIFEST="$ROOT/appliance/build/base-image.json"
OUT="${1:-$PWD/cape-inetsim-appliance-v1.0.0.qcow2}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[FAIL] missing build command: $1" >&2; exit 2; }; }
for x in python3 curl sha256sum qemu-img qemu-system-x86_64 cloud-localds virt-sysprep virt-cat virt-filesystems virt-resize virt-df virt-customize timeout; do need "$x"; done

readarray -t BASE < <(python3 - "$BASE_MANIFEST" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for k in ("url","sha256","image_name","release_build"):
    print(d[k])
PY
)
BASE_URL="${BASE[0]}"
BASE_SHA="${BASE[1]}"
BASE_NAME="${BASE[2]}"
BASE_BUILD="${BASE[3]}"
BASE_CACHE_ROOT="${APPLIANCE_BASE_CACHE:-}"
if [[ -n "$BASE_CACHE_ROOT" ]]; then
  mkdir -p "$BASE_CACHE_ROOT"
  BASE_FILE="$BASE_CACHE_ROOT/$BASE_NAME"
else
  BASE_FILE="$WORK/$BASE_NAME"
fi

if [[ -f "$BASE_FILE" && "$(sha256sum "$BASE_FILE" | awk '{print $1}')" == "$BASE_SHA" ]]; then
  echo "[INFO] using verified cached Ubuntu base release $BASE_BUILD"
else
  rm -f "$BASE_FILE.part"
  echo "[INFO] downloading pinned Ubuntu base release $BASE_BUILD"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 -o "$BASE_FILE.part" "$BASE_URL"
  [[ "$(sha256sum "$BASE_FILE.part" | awk '{print $1}')" == "$BASE_SHA" ]] || {
    rm -f "$BASE_FILE.part"
    echo "[FAIL] Ubuntu base image SHA-256 mismatch" >&2
    exit 3
  }
  mv "$BASE_FILE.part" "$BASE_FILE"
fi

rm -f "$OUT" "$OUT.part"

# Assert the pinned image layout before resizing. Ubuntu Noble cloud images use
# /dev/sda1 as the root partition; an upstream layout change must stop the build.
mapfile -t PARTITIONS < <(virt-filesystems -a "$BASE_FILE" --partitions 2>/dev/null)
printf '%s\n' "${PARTITIONS[@]}" | grep -Fxq /dev/sda1 || {
  echo "[FAIL] pinned Ubuntu image no longer exposes expected root partition /dev/sda1" >&2
  exit 5
}

qemu-img create -f qcow2 "$OUT.part" 20G >/dev/null
virt-resize --expand /dev/sda1 "$BASE_FILE" "$OUT.part"

# Provision through the cloud image's native boot path instead of depending on
# libguestfs appliance networking. QEMU user networking is build-time only.
USER_DATA="$WORK/user-data"
META_DATA="$WORK/meta-data"
SEED="$WORK/nocloud-seed.img"
CONSOLE="$WORK/qemu-console.log"
python3 "$ROOT/appliance/build/render-cloud-init.py"   --guest-configure "$ROOT/appliance/guest-configure.sh"   --prepare "$ROOT/appliance/image-rootfs-prepare.sh"   --output "$USER_DATA"
cat >"$META_DATA" <<'EOF_META'
instance-id: cape-inetsim-appliance-build-v1
local-hostname: cape-inetsim-build
EOF_META
cloud-localds "$SEED" "$USER_DATA" "$META_DATA"

QEMU_MACHINE=(-machine type=q35,accel=tcg -cpu max)
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  QEMU_MACHINE=(-machine type=q35,accel=kvm -cpu host)
fi

echo "[INFO] booting temporary isolated build VM to install appliance packages"
set +e
timeout --signal=TERM --kill-after=30s 1500 \
  qemu-system-x86_64 \
    "${QEMU_MACHINE[@]}" \
    -name cape-inetsim-appliance-build \
    -m 2048 -smp 2 \
    -drive "file=$OUT.part,if=virtio,format=qcow2,cache=unsafe" \
    -drive "file=$SEED,if=virtio,format=raw,readonly=on" \
    -netdev user,id=buildnet,restrict=off \
    -device virtio-net-pci,netdev=buildnet \
    -device virtio-rng-pci \
    -nographic -monitor none -no-reboot \
  2>&1 | tee "$CONSOLE"
QEMU_RC=${PIPESTATUS[0]}
set -e

if [[ "$QEMU_RC" -ne 0 ]]; then
  echo "[FAIL] temporary appliance build VM exited with status $QEMU_RC" >&2
  echo "----- guest provisioning log (if available) -----" >&2
  virt-cat -a "$OUT.part" /var/log/cape-inetsim-image-build.log >&2 || true
  echo "----- cloud-init output log (if available) -----" >&2
  virt-cat -a "$OUT.part" /var/log/cloud-init-output.log >&2 || true
  echo "----- qemu console tail -----" >&2
  tail -n 300 "$CONSOLE" >&2 || true
  if [[ -n "${APPLIANCE_DIAG_DIR:-}" ]]; then
    mkdir -p "$APPLIANCE_DIAG_DIR"
    cp -f "$CONSOLE" "$APPLIANCE_DIAG_DIR/qemu-console.log" 2>/dev/null || true
    cp -f "$USER_DATA" "$APPLIANCE_DIAG_DIR/user-data" 2>/dev/null || true
    cp -f "$META_DATA" "$APPLIANCE_DIAG_DIR/meta-data" 2>/dev/null || true
    virt-cat -a "$OUT.part" /var/log/cape-inetsim-image-build.log >"$APPLIANCE_DIAG_DIR/guest-provisioning.log" 2>/dev/null || true
    virt-cat -a "$OUT.part" /var/log/cloud-init-output.log >"$APPLIANCE_DIAG_DIR/cloud-init-output.log" 2>/dev/null || true
  fi
  exit 7
fi

if ! virt-cat -a "$OUT.part" /var/lib/cape-inetsim-build-ok >/dev/null 2>&1; then
  echo "[FAIL] appliance provisioning did not complete successfully" >&2
  echo "----- guest provisioning log -----" >&2
  virt-cat -a "$OUT.part" /var/log/cape-inetsim-image-build.log >&2 || true
  echo "----- qemu console tail -----" >&2
  tail -n 200 "$CONSOLE" >&2 || true
  exit 8
fi

# Remove build-only cloud-init state and marker files before generalizing.
virt-customize -a "$OUT.part"   --run-command 'rm -rf /var/lib/cloud/instances/* /var/lib/cloud/instance /var/lib/cape-inetsim-build-ok /var/lib/cape-inetsim-build-failed /var/log/cape-inetsim-image-build.log /root/cape-inetsim-image-rootfs-prepare /root/cape-inetsim-build-wrapper'

OPS="$(virt-sysprep --list-operations | awk '{print $1}' | tr '\n' ' ')"
required_ops=(machine-id ssh-hostkeys dhcp-client-state net-hostname)
selected=()
for op in "${required_ops[@]}"; do
  grep -qw "$op" <<<"$OPS" || { echo "[FAIL] virt-sysprep operation unavailable: $op" >&2; exit 4; }
  selected+=("$op")
done
virt-sysprep -a "$OUT.part" --operations "$(IFS=,; echo "${selected[*]}")"

qemu-img check "$OUT.part" >/dev/null
[[ "$(qemu-img info --output=json "$OUT.part" | python3 -c 'import json,sys;print(json.load(sys.stdin)["format"])')" == qcow2 ]]
VIRTUAL_SIZE="$(qemu-img info --output=json "$OUT.part" | python3 -c 'import json,sys;print(json.load(sys.stdin)["virtual-size"])')"
[[ "$VIRTUAL_SIZE" -ge 20000000000 ]] || { echo "[FAIL] appliance virtual disk was not expanded to ~20 GiB" >&2; exit 6; }
virt-df -a "$OUT.part" >/dev/null

OS_RELEASE="$(virt-cat -a "$OUT.part" /etc/os-release)"
grep -q '^VERSION_ID="24.04"$' <<<"$OS_RELEASE"
[[ "$(virt-cat -a "$OUT.part" /etc/sysctl.d/99-inetsim-lowports.conf | tr -d '\r')" == 'net.ipv4.ip_unprivileged_port_start=53' ]]
virt-cat -a "$OUT.part" /usr/local/sbin/cape-inetsim-guest-configure | grep -q -- '--management-mac'
virt-cat -a "$OUT.part" /etc/cloud/cloud-init.disabled >/dev/null

mv "$OUT.part" "$OUT"
sha256sum "$OUT" >"$OUT.sha256"
qemu-img info "$OUT" >"$OUT.info.txt"

echo "[PASS] generalized appliance built"
echo "ARTIFACT=$OUT"
echo "SHA256=$(awk '{print $1}' "$OUT.sha256")"

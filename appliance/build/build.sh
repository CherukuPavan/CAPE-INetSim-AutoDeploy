#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_MANIFEST="$ROOT/appliance/build/base-image.json"
OUT="${1:-$PWD/cape-inetsim-appliance-v1.0.0.qcow2}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[FAIL] missing build command: $1" >&2; exit 2; }; }
for x in python3 curl sha256sum qemu-img virt-customize virt-sysprep virt-cat virt-filesystems virt-resize virt-df; do need "$x"; done

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
BASE_FILE="$WORK/$BASE_NAME"

echo "[INFO] downloading pinned Ubuntu base release $BASE_BUILD"
curl --fail --location --proto '=https' --tlsv1.2 --retry 3 -o "$BASE_FILE" "$BASE_URL"
[[ "$(sha256sum "$BASE_FILE" | awk '{print $1}')" == "$BASE_SHA" ]] || {
  echo "[FAIL] Ubuntu base image SHA-256 mismatch" >&2
  exit 3
}

rm -f "$OUT" "$OUT.part"

# The Ubuntu cloud image root filesystem is on /dev/sda1. Assert that layout
# before resizing so a future upstream image-layout change stops the build.
mapfile -t PARTITIONS < <(virt-filesystems -a "$BASE_FILE" --partitions 2>/dev/null)
printf '%s\n' "${PARTITIONS[@]}" | grep -Fxq /dev/sda1 || {
  echo "[FAIL] pinned Ubuntu image no longer exposes expected root partition /dev/sda1" >&2
  exit 5
}

# Grow both the virtual disk and the guest root filesystem. qemu-img resize
# alone would leave the guest filesystem at the small cloud-image size.
qemu-img create -f qcow2 "$OUT.part" 20G >/dev/null
virt-resize --expand /dev/sda1 "$BASE_FILE" "$OUT.part"

export LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND:-direct}"
virt-customize -a "$OUT.part" --network   --mkdir /usr/local/src   --upload "$ROOT/appliance/guest-configure.sh:/usr/local/src/cape-inetsim-guest-configure"   --upload "$ROOT/appliance/image-rootfs-prepare.sh:/root/cape-inetsim-image-rootfs-prepare"   --chmod '0755:/root/cape-inetsim-image-rootfs-prepare'   --run /root/cape-inetsim-image-rootfs-prepare   --delete /root/cape-inetsim-image-rootfs-prepare

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

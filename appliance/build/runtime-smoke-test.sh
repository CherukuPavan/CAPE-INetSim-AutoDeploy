#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${1:-}"
[[ -n "$IMAGE" && -f "$IMAGE" ]] || { echo "[FAIL] usage: $0 IMAGE.qcow2" >&2; exit 2; }

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[FAIL] missing runtime-smoke command: $1" >&2; exit 2; }; }
for x in qemu-img qemu-system-x86_64 virt-copy-in guestfish virt-cat timeout; do need "$x"; done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OVERLAY="$WORK/runtime-smoke.qcow2"
WRAPPER="$WORK/cape-inetsim-runtime-smoke"
UNIT="$WORK/cape-inetsim-runtime-smoke.service"
CONSOLE="$WORK/console.log"
MGMT_MAC=52:54:00:aa:00:01
ISO_MAC=52:54:00:aa:00:02
ISO_CIDR=192.168.200.2/24
ISO_GATEWAY=192.168.200.1

qemu-img create -q -f qcow2 -F qcow2 -b "$(realpath "$IMAGE")" "$OVERLAY"

# The host deployer may use this baked helper only when QGA guest-file transport
# is unavailable, so release promotion must prove it is byte-identical to source.
virt-cat -a "$OVERLAY" /usr/local/sbin/cape-inetsim-guest-configure >"$WORK/baked-guest-configure"
cmp -s "$ROOT/appliance/guest-configure.sh" "$WORK/baked-guest-configure" || {
  echo "[FAIL] baked guest configurator does not match release source" >&2
  exit 1
}
echo "[PASS] baked guest configurator matches release source"

cat >"$WRAPPER" <<EOF
#!/bin/bash
set +e
/usr/local/sbin/cape-inetsim-guest-configure \
  --management-mac $MGMT_MAC \
  --isolated-mac $ISO_MAC \
  --ip $ISO_CIDR \
  --gateway $ISO_GATEWAY > /var/log/cape-inetsim-runtime-smoke.log 2>&1
rc=\$?
if [ "\$rc" -eq 0 ]; then
  systemctl restart lightdm.service >/dev/null 2>&1 || rc=90
fi
if [ "\$rc" -eq 0 ]; then
  gui_ok=no
  for _ in \$(seq 1 90); do
    if systemctl is-active --quiet lightdm.service &&
       test -f /etc/cape-inetsim-gui-v4 &&
       test -f /usr/lib/xorg/modules/drivers/qxl_drv.so &&
       test -S /tmp/.X11-unix/X0 &&
       pgrep -x Xorg >/dev/null &&
       grep -Fxq 'greeter-show-manual-login=true' /etc/lightdm/lightdm.conf.d/99-cape-inetsim-console-login.conf &&
       grep -Fxq 'user-session=cape-inetsim-xfce' /etc/lightdm/lightdm.conf.d/99-cape-inetsim-console-login.conf; then
      gui_ok=yes
      break
    fi
    sleep 1
  done
  [ "\$gui_ok" = yes ] || rc=91
fi
if [ "\$rc" -eq 0 ]; then
  touch /var/lib/cape-inetsim-runtime-smoke-ok
else
  printf '%s\n' "\$rc" >/var/lib/cape-inetsim-runtime-smoke-failed
  {
    echo "=== lightdm status ==="
    systemctl status lightdm.service --no-pager -l || true
    echo "=== lightdm journal ==="
    journalctl -u lightdm.service -b --no-pager -n 250 || true
    echo "=== processes ==="
    ps -ef || true
    echo "=== xsession errors ==="
    cat /home/capeinetsim/.xsession-errors 2>/dev/null || true
    echo "=== dedicated session log ==="
    cat /home/capeinetsim/.cape-inetsim-xfce-session.log 2>/dev/null || true
    echo "=== lightdm logs ==="
    for f in /var/log/lightdm/*.log; do
      [ -f "$f" ] || continue
      echo "--- $f ---"
      tail -n 250 "$f" || true
    done
  } > /var/log/cape-inetsim-gui-smoke.log 2>&1
fi
sync
poweroff -f
exit 0
EOF
chmod 0755 "$WRAPPER"

cat >"$UNIT" <<'EOF'
[Unit]
Description=CAPE INetSim appliance runtime smoke test
After=systemd-modules-load.service
Wants=network.target
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cape-inetsim-runtime-smoke
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

virt-copy-in -a "$OVERLAY" "$WRAPPER" /usr/local/sbin
virt-copy-in -a "$OVERLAY" "$UNIT" /etc/systemd/system
guestfish --rw -a "$OVERLAY" -i <<'EOF'
ln-s ../cape-inetsim-runtime-smoke.service /etc/systemd/system/multi-user.target.wants/cape-inetsim-runtime-smoke.service
EOF

QEMU_MACHINE=(-machine type=q35,accel=tcg -cpu max)
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  QEMU_MACHINE=(-machine type=q35,accel=kvm -cpu host)
fi

set +e
timeout --signal=TERM --kill-after=20s 240 \
  qemu-system-x86_64 \
    "${QEMU_MACHINE[@]}" \
    -name cape-inetsim-runtime-smoke \
    -m 2048 -smp 2 \
    -drive "file=$OVERLAY,if=virtio,format=qcow2,cache=unsafe" \
    -netdev user,id=mgmt,restrict=off \
    -device "virtio-net-pci,netdev=mgmt,mac=$MGMT_MAC" \
    -netdev user,id=isolated,restrict=on \
    -device "virtio-net-pci,netdev=isolated,mac=$ISO_MAC" \
    -vga qxl \
    -nographic -monitor none -no-reboot \
    >"$CONSOLE" 2>&1
QEMU_RC=$?
set -e

if virt-cat -a "$OVERLAY" /var/lib/cape-inetsim-runtime-smoke-ok >/dev/null 2>&1; then
  echo "[PASS] appliance runtime smoke test configured both NICs, started INetSim, and proved stable QXL/LightDM console login"
  exit 0
fi

echo "[FAIL] appliance runtime smoke test failed (qemu_rc=$QEMU_RC)" >&2
echo "----- guest runtime smoke log -----" >&2
virt-cat -a "$OVERLAY" /var/log/cape-inetsim-runtime-smoke.log >&2 || true
echo "----- guest GUI smoke log -----" >&2
virt-cat -a "$OVERLAY" /var/log/cape-inetsim-gui-smoke.log >&2 || true
echo "----- failure marker -----" >&2
virt-cat -a "$OVERLAY" /var/lib/cape-inetsim-runtime-smoke-failed >&2 || true
echo "----- console tail -----" >&2
tail -n 250 "$CONSOLE" >&2 || true
exit 1

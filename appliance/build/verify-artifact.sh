#!/usr/bin/env bash
set -Eeuo pipefail
IMG="${1:?usage: verify-artifact.sh IMAGE.qcow2}"
[[ -f "$IMG" ]] || { echo "missing image: $IMG" >&2; exit 2; }

qemu-img check "$IMG" >/dev/null
FMT="$(qemu-img info --output=json "$IMG" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("format",""))')"
[[ "$FMT" == qcow2 ]] || { echo "not qcow2: $FMT" >&2; exit 3; }

export LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND:-direct}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

virt-cat -a "$IMG" /etc/os-release >"$TMP/os-release"
grep -Eq '^VERSION_ID="?24\.04"?$' "$TMP/os-release"

virt-cat -a "$IMG" /etc/passwd >"$TMP/passwd"
grep -Eq '^capeinetsim:x:[0-9]+:[0-9]+:.*:/home/capeinetsim:/bin/bash$' "$TMP/passwd"

virt-cat -a "$IMG" /etc/lightdm/lightdm.conf.d/60-cape-inetsim.conf >"$TMP/lightdm.conf"
grep -Fq 'user-session=xfce' "$TMP/lightdm.conf"
grep -Fq 'autologin-user=capeinetsim' "$TMP/lightdm.conf"

virt-cat -a "$IMG" /home/capeinetsim/.xsession >"$TMP/xsession"
grep -Fq 'exec startxfce4' "$TMP/xsession"

virt-ls -a "$IMG" /usr/share/xsessions | grep -Fq 'xfce.desktop'
virt-ls -a "$IMG" /usr/local/sbin | grep -Fq 'cape-inetsim-guest-configure'
virt-ls -a "$IMG" /usr/local/sbin | grep -Fq 'cape-inetsim-gui-enable'
virt-ls -a "$IMG" /usr/bin | grep -Fq 'spice-vdagent'
virt-ls -a "$IMG" /usr/sbin | grep -Fq 'lightdm'

virt-cat -a "$IMG" /etc/inetsim/inetsim.conf >"$TMP/inetsim.conf"
grep -Eq '^[[:space:]]*service_bind_address[[:space:]]+' "$TMP/inetsim.conf"
grep -Eq '^[[:space:]]*dns_default_ip[[:space:]]+' "$TMP/inetsim.conf"

virt-cat -a "$IMG" /usr/share/perl5/INetSim/DNS.pm >"$TMP/DNS.pm"
grep -Fq 'loop_once(10)' "$TMP/DNS.pm"

virt-cat -a "$IMG" /etc/sysctl.d/99-inetsim-lowports.conf | grep -Fq 'net.ipv4.ip_unprivileged_port_start=53'

# Generalization/privacy gates.
MID="$(virt-cat -a "$IMG" /etc/machine-id 2>/dev/null || true)"
[[ -z "${MID//[[:space:]]/}" ]] || { echo "machine-id is not generalized" >&2; exit 10; }
if virt-ls -a "$IMG" /etc/ssh 2>/dev/null | grep -Eq '^ssh_host_.*_key(\.pub)?$'; then
  echo "SSH host keys remain in generalized appliance" >&2
  exit 11
fi

# The image must not contain a deployment-specific isolated subnet.
if virt-cat -a "$IMG" /etc/netplan/90-cape-inetsim-isolated.yaml >/dev/null 2>&1; then
  echo "deployment-specific isolated netplan is baked into appliance" >&2
  exit 12
fi

echo "APPLIANCE_VERIFY_PASS format=qcow2 os=ubuntu24.04 gui=xfce/lightdm services=inetsim qga=yes"

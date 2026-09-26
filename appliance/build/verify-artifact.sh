#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${1:-}"
[[ -n "$IMAGE" && -f "$IMAGE" ]] || { echo "[FAIL] usage: $0 IMAGE.qcow2" >&2; exit 2; }

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[FAIL] missing verifier command: $1" >&2; exit 2; }; }
for x in qemu-img virt-cat virt-ls python3 grep; do need "$x"; done

info_json="$(qemu-img info --output=json "$IMAGE")"
python3 - "$info_json" <<'PY'
import json,sys
d=json.loads(sys.argv[1])
if d.get("format")!="qcow2":
    raise SystemExit("candidate is not qcow2")
for k in ("backing-filename","full-backing-filename","data-file","full-data-filename"):
    if d.get(k):
        raise SystemExit(f"candidate has forbidden external dependency: {k}")
if int(d.get("virtual-size",0)) < 20_000_000_000:
    raise SystemExit("candidate virtual size is below 20 GiB policy")
PY
qemu-img check "$IMAGE" >/dev/null

os_release="$(virt-cat -a "$IMAGE" /etc/os-release)"
grep -Fxq 'VERSION_ID="24.04"' <<<"$os_release"

lowports="$(virt-cat -a "$IMAGE" /etc/sysctl.d/99-inetsim-lowports.conf | tr -d '\r')"
[[ "$lowports" == 'net.ipv4.ip_unprivileged_port_start=53' ]]

isolation="$(virt-cat -a "$IMAGE" /etc/sysctl.d/99-cape-inetsim-isolation.conf | tr -d '\r')"
grep -Fxq 'net.ipv4.ip_forward=0' <<<"$isolation"
grep -Fxq 'net.ipv6.conf.all.forwarding=0' <<<"$isolation"

guest_config="$(virt-cat -a "$IMAGE" /usr/local/sbin/cape-inetsim-guest-configure)"
grep -Fq -- '--management-mac' <<<"$guest_config"
grep -Fq -- '--isolated-mac' <<<"$guest_config"
grep -Fq 'service_bind_address' <<<"$guest_config"
grep -Fq 'dns_default_ip' <<<"$guest_config"
! grep -Eq '192\.168\.200\.|192\.168\.122\.' <<<"$guest_config"

dns_pm="$(virt-cat -a "$IMAGE" /usr/share/perl5/INetSim/DNS.pm)"
grep -Fq 'loop_once(10)' <<<"$dns_pm"

virt-cat -a "$IMAGE" /etc/cloud/cloud-init.disabled >/dev/null

if virt-cat -a "$IMAGE" /etc/netplan/90-cape-inetsim.yaml >/dev/null 2>&1; then
  echo "[FAIL] candidate already contains deployment-owned netplan state" >&2
  exit 5
fi
if virt-cat -a "$IMAGE" /etc/cape-inetsim-build-dns >/dev/null 2>&1; then
  echo "[FAIL] candidate still contains temporary build DNS state" >&2
  exit 5
fi
netplan_listing="$(virt-ls -a "$IMAGE" /etc/netplan 2>/dev/null || true)"
while IFS= read -r netplan_name; do
  case "$netplan_name" in
    *.yaml|*.yml) ;;
    *) continue ;;
  esac
  netplan_text="$(virt-cat -a "$IMAGE" "/etc/netplan/$netplan_name" 2>/dev/null || true)"
  if grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}|^[[:space:]]*gateway4:|^[[:space:]]*to:[[:space:]]*default([[:space:]]|$)' <<<"$netplan_text"; then
    echo "[FAIL] candidate contains persistent static/default network configuration in /etc/netplan/$netplan_name" >&2
    exit 5
  fi
done <<<"$netplan_listing"

machine_id="$(virt-cat -a "$IMAGE" /etc/machine-id 2>/dev/null | tr -d '[:space:]' || true)"
python3 - "$machine_id" <<'PY'
import re,sys
v=sys.argv[1].lower()
if re.fullmatch(r"[0-9a-f]{32}",v) and v != "0"*32:
    raise SystemExit("candidate contains a persistent machine-id")
PY

ssh_listing="$(virt-ls -a "$IMAGE" /etc/ssh 2>/dev/null || true)"
if grep -Eq '^ssh_host_.*_key$' <<<"$ssh_listing"; then
  echo "[FAIL] candidate contains persistent SSH host private keys" >&2
  exit 3
fi

dpkg_status="$(virt-cat -a "$IMAGE" /var/lib/dpkg/status)"
for pkg in   inetsim qemu-guest-agent xubuntu-desktop-minimal xubuntu-default-settings   lightdm lightdm-gtk-greeter accountsservice xserver-xorg-video-qxl spice-vdagent; do
  grep -Eq "^Package: ${pkg}$" <<<"$dpkg_status" || {
    echo "[FAIL] candidate is missing required package: $pkg" >&2
    exit 6
  }
done

xorg_drivers="$(virt-ls -a "$IMAGE" /usr/lib/xorg/modules/drivers 2>/dev/null || true)"
grep -Fxq 'qxl_drv.so' <<<"$xorg_drivers" || {
  echo "[FAIL] candidate is missing the QXL Xorg driver required by the libvirt SPICE/QXL console" >&2
  exit 6
}

virt-cat -a "$IMAGE" /etc/cape-inetsim-gui-v6 >/dev/null
xubuntu_desktop="$(virt-cat -a "$IMAGE" /usr/share/xsessions/xubuntu.desktop)"
grep -Eq '^Exec=.*startxfce4' <<<"$xubuntu_desktop" || {
  echo "[FAIL] Xubuntu xsession entry does not launch startxfce4" >&2
  exit 7
}

lightdm_policy="$(virt-cat -a "$IMAGE" /etc/lightdm/lightdm.conf.d/99-cape-inetsim-console-login.conf)"
for required in   'user-session=xubuntu'   'allow-user-switching=false'   'allow-guest=false'   'greeter-hide-users=false'   'greeter-show-manual-login=false'; do
  grep -Fxq "$required" <<<"$lightdm_policy" || {
    echo "[FAIL] candidate is missing LightDM console policy: $required" >&2
    exit 7
  }
done
! grep -Eq '^autologin-user=' <<<"$lightdm_policy" || {
  echo "[FAIL] immutable candidate unexpectedly enables LightDM autologin" >&2
  exit 7
}

passwd_db="$(virt-cat -a "$IMAGE" /etc/passwd)"
shadow_db="$(virt-cat -a "$IMAGE" /etc/shadow)"
python3 - "$passwd_db" "$shadow_db" "$IMAGE" <<'PY'
import subprocess,sys
passwd,shadow,image=sys.argv[1:]
users={}
for line in passwd.splitlines():
    p=line.split(":")
    if len(p)<7:
        continue
    try:
        uid=int(p[2])
    except ValueError:
        continue
    users[p[0]]={"uid":uid,"home":p[5],"shell":p[6]}

gui=[u for u,v in users.items() if v["uid"]>=1000 and not v["shell"].endswith(("nologin","false"))]
if gui != ["capeinetsim"]:
    raise SystemExit("expected exactly one interactive non-root account (capeinetsim), got: "+",".join(gui))

if "ubuntu" in users and not users["ubuntu"]["shell"].endswith("nologin"):
    raise SystemExit("cloud bootstrap user ubuntu is still interactive")

dmrc=subprocess.check_output(["virt-cat","-a",image,"/home/capeinetsim/.dmrc"],text=True)
if "Session=xubuntu" not in dmrc.splitlines():
    raise SystemExit("capeinetsim .dmrc is not pinned to xubuntu")

acc=subprocess.check_output(["virt-cat","-a",image,"/var/lib/AccountsService/users/capeinetsim"],text=True)
lines=set(acc.splitlines())
for required in ("Session=xubuntu","XSession=xubuntu","SystemAccount=false"):
    if required not in lines:
        raise SystemExit("capeinetsim AccountsService mapping missing "+required)

if "ubuntu" in users:
    uacc=subprocess.check_output(["virt-cat","-a",image,"/var/lib/AccountsService/users/ubuntu"],text=True)
    if "SystemAccount=true" not in uacc.splitlines():
        raise SystemExit("ubuntu cloud bootstrap account is not hidden from AccountsService")

sh={}
for line in shadow.splitlines():
    p=line.split(":")
    if len(p)>=2:
        sh[p[0]]=p[1]
for user in ("root","capeinetsim"):
    token=sh.get(user,"")
    if not token or token[0] not in ("!","*"):
        raise SystemExit(user+" has a usable password in the immutable image")
PY

ssh_policy="$(virt-cat -a "$IMAGE" /etc/ssh/sshd_config.d/99-cape-inetsim-no-password-auth.conf)"
grep -Fxq 'PasswordAuthentication no' <<<"$ssh_policy"
grep -Fxq 'KbdInteractiveAuthentication no' <<<"$ssh_policy"
grep -Fxq 'PermitRootLogin no' <<<"$ssh_policy"

cloud_instances="$(virt-ls -R -a "$IMAGE" /var/lib/cloud/instances 2>/dev/null || true)"
[[ -z "${cloud_instances//[[:space:]]/}" ]] || {
  echo "[FAIL] candidate still contains cloud-init instance state" >&2
  exit 4
}

echo "[PASS] generalized INetSim appliance artifact verification"

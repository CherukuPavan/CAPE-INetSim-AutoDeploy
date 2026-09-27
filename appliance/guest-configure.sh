#!/usr/bin/env bash
set -Eeuo pipefail

usage(){ echo "usage: $0 --isolated-mac MAC --ip CIDR" >&2; exit 2; }
MAC=""; CIDR=""
while (($#)); do
  case "$1" in
    --isolated-mac) MAC="${2,,}"; shift 2 ;;
    --ip) CIDR="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$MAC" && -n "$CIDR" ]] || usage

IP="${CIDR%/*}"
python3 - "$CIDR" <<'PY'
import ipaddress,sys
n=ipaddress.ip_interface(sys.argv[1])
if not n.ip.is_private: raise SystemExit('isolated address must be private')
PY

IFACE=""
for p in /sys/class/net/*; do
  [[ -f "$p/address" ]] || continue
  if [[ "$(tr '[:upper:]' '[:lower:]' <"$p/address")" == "$MAC" ]]; then IFACE="$(basename "$p")"; break; fi
done
[[ -n "$IFACE" ]] || { echo "interface for MAC $MAC not found" >&2; exit 30; }

# Configure only the isolated NIC. The management NIC/default route stay untouched.
cat >/etc/netplan/90-cape-inetsim-isolated.yaml <<EOF2
network:
  version: 2
  ethernets:
    cape_inetsim_isolated:
      match:
        macaddress: "$MAC"
      set-name: "$IFACE"
      addresses:
        - "$CIDR"
      dhcp4: false
      dhcp6: false
      link-local: []
EOF2
chmod 0600 /etc/netplan/90-cape-inetsim-isolated.yaml
netplan generate
netplan apply

DEFAULTS="$(ip -4 route show default | wc -l)"
[[ "$DEFAULTS" -eq 1 ]] || { echo "expected exactly one management default route, found $DEFAULTS" >&2; exit 31; }

CONF=/etc/inetsim/inetsim.conf
[[ -f "$CONF.pre-autodeploy" ]] || cp -a "$CONF" "$CONF.pre-autodeploy"
python3 - "$CONF" "$IP" <<'PY'
import re,sys
p,ip=sys.argv[1:]
s=open(p).read()
def set_one(text,key,value):
    pat=re.compile(rf'(?m)^\s*#?\s*{re.escape(key)}\s+\S+\s*$')
    if not pat.search(text): raise SystemExit(f'missing {key} in {p}')
    return pat.sub(f'{key} {value}',text,count=1)
s=set_one(s,'service_bind_address',ip)
s=set_one(s,'dns_default_ip',ip)
open(p,'w').write(s)
PY

sysctl --system >/dev/null
[[ "$(sysctl -n net.ipv4.ip_unprivileged_port_start)" == 53 ]]
systemctl enable inetsim.service >/dev/null
systemctl restart inetsim.service
sleep 2

ip -4 addr show dev "$IFACE" | grep -Fq "$CIDR"
for port in 53 80 443 25 21; do
  ss -lntup | grep -Eq "[$][:]?$port|$IP:$port" || {
    echo "expected INetSim listener missing on port $port" >&2
    exit 32
  }
done
systemctl is-active --quiet inetsim.service
systemctl is-active --quiet qemu-guest-agent.service
systemctl is-active --quiet lightdm.service
id capeinetsim >/dev/null
test -f /usr/share/xsessions/xfce.desktop
command -v spice-vdagent >/dev/null

echo "INETSIM_GUEST_CONFIG_OK iface=$IFACE ip=$CIDR services=dns,http,https,smtp,ftp gui=xfce"

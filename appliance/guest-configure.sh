#!/usr/bin/env bash
set -Eeuo pipefail

usage(){ echo "usage: $0 --management-mac MAC --isolated-mac MAC --ip CIDR --gateway IP [--client-ip IP ...]" >&2; exit 2; }
MGMT_MAC=""; ISO_MAC=""; CIDR=""; GATEWAY=""
CLIENT_IPS=()
while (($#)); do
  case "$1" in
    --management-mac) MGMT_MAC="${2,,}"; shift 2 ;;
    --isolated-mac) ISO_MAC="${2,,}"; shift 2 ;;
    --ip) CIDR="$2"; shift 2 ;;
    --gateway) GATEWAY="$2"; shift 2 ;;
    --client-ip) CLIENT_IPS+=("$2"); shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$MGMT_MAC" && -n "$ISO_MAC" && -n "$CIDR" && -n "$GATEWAY" ]] || usage
[[ "$MGMT_MAC" != "$ISO_MAC" ]] || { echo "management and isolated MACs are identical" >&2; exit 29; }

IP="${CIDR%/*}"
python3 - "$CIDR" "$GATEWAY" "${CLIENT_IPS[@]}" <<'PY'
import ipaddress,sys
n=ipaddress.ip_interface(sys.argv[1])
g=ipaddress.ip_address(sys.argv[2])
if not n.ip.is_private: raise SystemExit('isolated address must be private')
if g not in n.network: raise SystemExit('isolated gateway must be on the isolated subnet')
for raw in sys.argv[3:]:
    ipaddress.ip_address(raw)
PY

iface_for_mac() {
  local want="${1,,}" p
  for p in /sys/class/net/*; do
    [[ -f "$p/address" ]] || continue
    if [[ "$(tr '[:upper:]' '[:lower:]' <"$p/address")" == "$want" ]]; then basename "$p"; return 0; fi
  done
  return 1
}

MGMT_IF="$(iface_for_mac "$MGMT_MAC")" || { echo "management interface for MAC $MGMT_MAC not found" >&2; exit 30; }
ISO_IF="$(iface_for_mac "$ISO_MAC")" || { echo "isolated interface for MAC $ISO_MAC not found" >&2; exit 31; }
[[ "$MGMT_IF" != "$ISO_IF" ]] || { echo "management and isolated interfaces resolved to same device" >&2; exit 32; }

# Both interfaces are rendered by MAC so deploy-time interface names are never
# assumptions. Only management gets DHCP/default routing. Isolated gets no DNS,
# gateway, DHCP or link-local fallback.
cat >/etc/netplan/90-cape-inetsim.yaml <<EOF2
network:
  version: 2
  ethernets:
    cape_inetsim_management:
      match:
        macaddress: "$MGMT_MAC"
      set-name: "$MGMT_IF"
      dhcp4: true
      dhcp6: false
    cape_inetsim_isolated:
      match:
        macaddress: "$ISO_MAC"
      set-name: "$ISO_IF"
      addresses:
        - "$CIDR"
      dhcp4: false
      dhcp6: false
      accept-ra: false
      link-local: []
EOF2

if (("${#CLIENT_IPS[@]}" > 0)); then
  {
    echo "      routes:"
    for client in "${CLIENT_IPS[@]}"; do
      echo "        - to: ${client}/32"
      echo "          via: ${GATEWAY}"
    done
  } >>/etc/netplan/90-cape-inetsim.yaml
fi
chmod 0600 /etc/netplan/90-cape-inetsim.yaml

# Remove cloud-image generated network definitions so they cannot race/duplicate
# the deployment-owned MAC-based netplan.
find /etc/netplan -maxdepth 1 -type f ! -name '90-cape-inetsim.yaml' -delete
netplan generate
netplan apply

DEFAULT_ROUTE="$(ip -4 route show default)"
DEFAULTS="$(awk 'NF{n++} END{print n+0}' <<<"$DEFAULT_ROUTE")"
[[ "$DEFAULTS" -le 1 ]] || { echo "expected at most one management default route, found $DEFAULTS" >&2; exit 33; }
if [[ "$DEFAULTS" -eq 1 ]]; then
  grep -Fq "dev $MGMT_IF" <<<"$DEFAULT_ROUTE" || { echo "default route is not on management interface $MGMT_IF" >&2; exit 34; }
  ! grep -Fq "dev $ISO_IF" <<<"$DEFAULT_ROUTE" || { echo "isolated interface $ISO_IF unexpectedly has a default route" >&2; exit 35; }
fi

for client in "${CLIENT_IPS[@]}"; do
  route_ready=no
  route_result=""
  for _ in $(seq 1 30); do
    route_result="$(ip -4 route get "$client" 2>/dev/null || true)"
    if grep -Fq "via $GATEWAY dev $ISO_IF" <<<"$route_result"; then
      route_ready=yes
      break
    fi
    sleep 1
  done
  if [[ "$route_ready" != yes ]]; then
    echo "client return route is not isolated after 30 seconds: $client" >&2
    echo "--- route lookup ---" >&2
    printf '%s\n' "$route_result" >&2
    echo "--- route table ---" >&2
    ip -4 route >&2 || true
    exit 37
  fi
done

CONF=/etc/inetsim/inetsim.conf
[[ -f "$CONF.pre-autodeploy" ]] || cp -a "$CONF" "$CONF.pre-autodeploy"
python3 - "$CONF" "$IP" <<'PY'
import re,sys
p,ip=sys.argv[1:]
s=open(p).read()
def set_one(text,key,value):
    pat=re.compile(rf'(?m)^\s*#?\s*{re.escape(key)}\s+\S+\s*
PY

sysctl -w net.ipv4.ip_unprivileged_port_start=53 >/dev/null
sysctl -w net.ipv4.ip_forward=0 >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null
[[ "$(sysctl -n net.ipv4.ip_unprivileged_port_start)" == 53 ]]
[[ "$(sysctl -n net.ipv4.ip_forward)" == 0 ]]
[[ "$(sysctl -n net.ipv6.conf.all.forwarding)" == 0 ]]
systemctl enable inetsim.service >/dev/null
systemctl restart inetsim.service

ready=no
ISO_ADDRS=""
UDP_LISTEN=""
TCP_LISTEN=""
for _ in $(seq 1 30); do
  ISO_ADDRS="$(ip -4 addr show dev "$ISO_IF" 2>/dev/null || true)"
  UDP_LISTEN="$(ss -lnup 2>/dev/null || true)"
  TCP_LISTEN="$(ss -lntp 2>/dev/null || true)"
  if grep -Fq "$CIDR" <<<"$ISO_ADDRS" &&
     grep -Fq "$IP:53" <<<"$UDP_LISTEN" &&
     grep -Eq "$IP:21[[:space:]]" <<<"$TCP_LISTEN" &&
     grep -Eq "$IP:25[[:space:]]" <<<"$TCP_LISTEN" &&
     grep -Eq "$IP:80[[:space:]]" <<<"$TCP_LISTEN" &&
     grep -Eq "$IP:443[[:space:]]" <<<"$TCP_LISTEN"; then
    ready=yes
    break
  fi
  sleep 1
done

if [[ "$ready" != yes ]]; then
  echo "INetSim services did not become ready within 30 seconds" >&2
  echo "--- ip -4 addr ---" >&2
  ip -4 addr >&2 || true
  echo "--- ip -4 route ---" >&2
  ip -4 route >&2 || true
  echo "--- listeners ---" >&2
  ss -lnupt >&2 || true
  echo "--- inetsim status ---" >&2
  systemctl status inetsim.service --no-pager -l >&2 || true
  echo "--- inetsim journal ---" >&2
  journalctl -u inetsim.service -n 100 --no-pager >&2 || true
  exit 36
fi

echo "INETSIM_GUEST_CONFIG_OK management=$MGMT_IF isolated=$ISO_IF ip=$CIDR"
)
    if not pat.search(text): raise SystemExit(f'missing {key} in {p}')
    return pat.sub(f'{key} {value}',text,count=1)
s=set_one(s,'service_bind_address',ip)
s=set_one(s,'dns_default_ip',ip)

# Production contract: these protocols are always available on the isolated
# appliance. Normalize duplicates and uncomment exactly one declaration.
for service in ("dns","http","https","smtp","ftp"):
    pat=re.compile(rf'(?m)^\s*#?\s*start_service\s+{re.escape(service)}\s*
PY

sysctl -w net.ipv4.ip_unprivileged_port_start=53 >/dev/null
sysctl -w net.ipv4.ip_forward=0 >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null
[[ "$(sysctl -n net.ipv4.ip_unprivileged_port_start)" == 53 ]]
[[ "$(sysctl -n net.ipv4.ip_forward)" == 0 ]]
[[ "$(sysctl -n net.ipv6.conf.all.forwarding)" == 0 ]]
systemctl enable inetsim.service >/dev/null
systemctl restart inetsim.service

ready=no
ISO_ADDRS=""
UDP_LISTEN=""
TCP_LISTEN=""
for _ in $(seq 1 30); do
  ISO_ADDRS="$(ip -4 addr show dev "$ISO_IF" 2>/dev/null || true)"
  UDP_LISTEN="$(ss -lnup 2>/dev/null || true)"
  TCP_LISTEN="$(ss -lntp 2>/dev/null || true)"
  if grep -Fq "$CIDR" <<<"$ISO_ADDRS" &&
     grep -Fq "$IP:53" <<<"$UDP_LISTEN" &&
     grep -Eq "$IP:80[[:space:]]" <<<"$TCP_LISTEN" &&
     grep -Eq "$IP:443[[:space:]]" <<<"$TCP_LISTEN"; then
    ready=yes
    break
  fi
  sleep 1
done

if [[ "$ready" != yes ]]; then
  echo "INetSim services did not become ready within 30 seconds" >&2
  echo "--- ip -4 addr ---" >&2
  ip -4 addr >&2 || true
  echo "--- ip -4 route ---" >&2
  ip -4 route >&2 || true
  echo "--- listeners ---" >&2
  ss -lnupt >&2 || true
  echo "--- inetsim status ---" >&2
  systemctl status inetsim.service --no-pager -l >&2 || true
  echo "--- inetsim journal ---" >&2
  journalctl -u inetsim.service -n 100 --no-pager >&2 || true
  exit 36
fi

echo "INETSIM_GUEST_CONFIG_OK management=$MGMT_IF isolated=$ISO_IF ip=$CIDR"
)
    hits=list(pat.finditer(s))
    if not hits:
        s += f"\nstart_service {service}\n"
        continue
    first=True
    def repl(m):
        nonlocal first
        if first:
            first=False
            return f"start_service {service}"
        return f"# duplicate disabled by CAPE-INetSim-AutoDeploy: start_service {service}"
    s=pat.sub(repl,s)
open(p,'w').write(s)
PY

sysctl -w net.ipv4.ip_unprivileged_port_start=53 >/dev/null
sysctl -w net.ipv4.ip_forward=0 >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null
[[ "$(sysctl -n net.ipv4.ip_unprivileged_port_start)" == 53 ]]
[[ "$(sysctl -n net.ipv4.ip_forward)" == 0 ]]
[[ "$(sysctl -n net.ipv6.conf.all.forwarding)" == 0 ]]
systemctl enable inetsim.service >/dev/null
systemctl restart inetsim.service

ready=no
ISO_ADDRS=""
UDP_LISTEN=""
TCP_LISTEN=""
for _ in $(seq 1 30); do
  ISO_ADDRS="$(ip -4 addr show dev "$ISO_IF" 2>/dev/null || true)"
  UDP_LISTEN="$(ss -lnup 2>/dev/null || true)"
  TCP_LISTEN="$(ss -lntp 2>/dev/null || true)"
  if grep -Fq "$CIDR" <<<"$ISO_ADDRS" &&
     grep -Fq "$IP:53" <<<"$UDP_LISTEN" &&
     grep -Eq "$IP:80[[:space:]]" <<<"$TCP_LISTEN" &&
     grep -Eq "$IP:443[[:space:]]" <<<"$TCP_LISTEN"; then
    ready=yes
    break
  fi
  sleep 1
done

if [[ "$ready" != yes ]]; then
  echo "INetSim services did not become ready within 30 seconds" >&2
  echo "--- ip -4 addr ---" >&2
  ip -4 addr >&2 || true
  echo "--- ip -4 route ---" >&2
  ip -4 route >&2 || true
  echo "--- listeners ---" >&2
  ss -lnupt >&2 || true
  echo "--- inetsim status ---" >&2
  systemctl status inetsim.service --no-pager -l >&2 || true
  echo "--- inetsim journal ---" >&2
  journalctl -u inetsim.service -n 100 --no-pager >&2 || true
  exit 36
fi

echo "INETSIM_GUEST_CONFIG_OK management=$MGMT_IF isolated=$ISO_IF ip=$CIDR"

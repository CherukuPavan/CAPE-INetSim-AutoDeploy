#!/usr/bin/env bash

collect_used_cidrs() {
  {
    ip -o -4 addr show 2>/dev/null | awk '{print $4}'
    ip -4 route show table all 2>/dev/null | awk '$1 ~ /^[0-9]+\./ && $1 ~ /\// {print $1}'
    local n
    for n in "${LIBVIRT_NETWORKS[@]:-}"; do
      virsh net-dumpxml "$n" 2>/dev/null | python3 -c '
import ipaddress,sys,xml.etree.ElementTree as ET
try: root=ET.fromstring(sys.stdin.read())
except Exception: raise SystemExit
for x in root.findall("ip"):
    a=x.get("address"); m=x.get("netmask"); p=x.get("prefix")
    if not a: continue
    try:
        if p: print(ipaddress.ip_network(f"{a}/{p}",strict=False))
        elif m: print(ipaddress.ip_network(f"{a}/{m}",strict=False))
    except ValueError: pass
' || true
    done
  } | sed '/^$/d' | sort -u
}

plan_isolated_subnet() {
  local f
  f="$(mktemp)"
  collect_used_cidrs >"$f"
  mapfile -t USED_CIDRS <"$f"
  ISOLATED_SUBNET="$(python3 - "$f" <<'PY'
import ipaddress,sys
used=[]
for s in open(sys.argv[1]):
    try: used.append(ipaddress.ip_network(s.strip(),strict=False))
    except ValueError: pass
candidates=[ipaddress.ip_network('192.168.200.0/24')]
candidates += [ipaddress.ip_network(f'172.31.{i}.0/24') for i in range(200,256)]
candidates += [ipaddress.ip_network(f'10.250.{i}.0/24') for i in range(1,255)]
for c in candidates:
    if all(not c.overlaps(u) for u in used): print(c); break
PY
)"
  rm -f "$f"
  if [[ -z "$ISOLATED_SUBNET" ]]; then add_error "No unused candidate private /24 subnet could be selected"; return 0; fi
  read -r BRIDGE_IP INETSIM_IP WINDOWS_FAKE_IP < <(python3 - "$ISOLATED_SUBNET" <<'PY'
import ipaddress,sys
n=ipaddress.ip_network(sys.argv[1]); print(n.network_address+1,n.network_address+2,n.network_address+10)
PY
)
}

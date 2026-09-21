#!/usr/bin/env bash

bridge_name_free() {
  local b="$1"
  ! ip link show "$b" >/dev/null 2>&1
}

network_name_free() {
  local n="$1"
  ! virsh net-info "$n" >/dev/null 2>&1
}

plan_resource_names() {
  local idx net bridge
  PLANNED_NETWORK_NAME=""
  PLANNED_BRIDGE_NAME=""

  for idx in "" {2..99}; do
    net="cape-inetsim-net${idx}"
    bridge="virbr-inet${idx}"
    if network_name_free "$net" && bridge_name_free "$bridge"; then
      PLANNED_NETWORK_NAME="$net"
      PLANNED_BRIDGE_NAME="$bridge"
      break
    fi
  done

  [[ -n "$PLANNED_NETWORK_NAME" ]] || add_error "No free AutoDeploy libvirt network/bridge name pair found"
}

render_isolated_network_xml() {
  local out="$1"
  [[ -n "${PLANNED_NETWORK_NAME:-}" && -n "${PLANNED_BRIDGE_NAME:-}" ]] || return 1
  cat >"$out" <<XML
<network>
  <name>${PLANNED_NETWORK_NAME}</name>
  <bridge name='${PLANNED_BRIDGE_NAME}' stp='on' delay='0'/>
  <ip address='${BRIDGE_IP}' prefix='24'/>
</network>
XML
}

validate_isolated_network_xml() {
  local xml="$1"
  python3 - "$xml" "${PLANNED_NETWORK_NAME}" "${PLANNED_BRIDGE_NAME}" "${BRIDGE_IP}" <<'PY'
import sys,xml.etree.ElementTree as ET
path,name,bridge,ip=sys.argv[1:5]
r=ET.parse(path).getroot()
assert r.tag=="network"
assert (r.findtext("name") or "").strip()==name
assert r.find("forward") is None, "isolated network must not contain <forward>"
b=r.find("bridge"); assert b is not None and b.get("name")==bridge
x=r.find("ip"); assert x is not None and x.get("address")==ip and x.get("prefix")=="24"
assert x.find("dhcp") is None, "isolated network must not provide DHCP"
print("OK")
PY
}

#!/usr/bin/env bash

isolated_network_defaults() {
  ISOLATED_NETWORK_NAME="${ISOLATED_NETWORK_NAME:-cape-inetsim-isolated}"
}

bridge_name_in_use() {
  local b="$1"
  ip link show dev "$b" >/dev/null 2>&1 && return 0
  local n xml
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    xml="$(virsh net-dumpxml "$n" 2>/dev/null || true)"
    grep -Fq "<bridge name='$b'" <<<"$xml" && return 0
    grep -Fq "<bridge name=\"$b\"" <<<"$xml" && return 0
  done < <(virsh net-list --all --name 2>/dev/null)
  return 1
}

choose_isolated_bridge_name() {
  local i candidate
  if [[ -n "${ISOLATED_BRIDGE_NAME:-}" ]]; then return 0; fi
  for i in $(seq 0 99); do
    candidate="capeisim$i"
    if ! bridge_name_in_use "$candidate"; then
      ISOLATED_BRIDGE_NAME="$candidate"
      return 0
    fi
  done
  add_error "No unused CAPE-INetSim bridge name could be selected"
  return 1
}

render_isolated_network_xml() {
  local name="$1" bridge="$2" cidr="$3" bridge_ip="$4"
  python3 - "$name" "$bridge" "$cidr" "$bridge_ip" <<'PY'
import ipaddress,sys,xml.sax.saxutils as x
name,bridge,cidr,bridge_ip=sys.argv[1:]
net=ipaddress.ip_network(cidr, strict=False)
print("<network>")
print(f"  <name>{x.escape(name)}</name>")
print(f"  <bridge name='{x.escape(bridge)}' stp='on' delay='0'/>")
print(f"  <ip address='{x.escape(bridge_ip)}' netmask='{net.netmask}'/>")
print("</network>")
PY
}

network_xml_facts() {
  python3 -c '
import ipaddress,sys,xml.etree.ElementTree as ET
try: root=ET.fromstring(sys.stdin.read())
except Exception:
    print("INVALID|||||yes")
    raise SystemExit
name=(root.findtext("name") or "")
b=root.find("bridge")
ip=root.find("ip")
forward=root.find("forward")
bridge=b.get("name","") if b is not None else ""
addr=ip.get("address","") if ip is not None else ""
mask=ip.get("netmask","") if ip is not None else ""
prefix=ip.get("prefix","") if ip is not None else ""
cidr=""
if addr:
    try: cidr=str(ipaddress.ip_network(f"{addr}/{prefix or mask}", strict=False))
    except Exception: pass
print("|".join(["OK",name,bridge,addr,cidr,"yes" if forward is not None else "no"]))
'
}

verify_isolated_network_definition() {
  local name="$1" expected_bridge="$2" expected_cidr="$3" expected_ip="$4"
  local xml facts status got_name got_bridge got_ip got_cidr has_forward
  xml="$(virsh net-dumpxml "$name" 2>/dev/null)" || return 1
  facts="$(network_xml_facts <<<"$xml")"
  IFS='|' read -r status got_name got_bridge got_ip got_cidr has_forward <<<"$facts"
  [[ "$status" == OK ]] || return 1
  [[ "$got_name" == "$name" ]] || return 1
  [[ "$got_bridge" == "$expected_bridge" ]] || return 1
  [[ "$got_cidr" == "$expected_cidr" ]] || return 1
  [[ "$got_ip" == "$expected_ip" ]] || return 1
  [[ "$has_forward" == no ]] || return 1
}

isolated_network_exists() { virsh net-info "$1" >/dev/null 2>&1; }

isolated_network_is_active() {
  local text
  text="$(virsh net-info "$1" 2>/dev/null)" || return 1
  grep -Eq '^Active:[[:space:]]+yes' <<<"$text"
}

isolated_network_apply() {
  isolated_network_defaults
  choose_isolated_bridge_name
  state_init_paths

  if isolated_network_exists "$ISOLATED_NETWORK_NAME"; then
    if verify_isolated_network_definition "$ISOLATED_NETWORK_NAME" "$ISOLATED_BRIDGE_NAME" "$ISOLATED_SUBNET" "$BRIDGE_IP"; then
      if state_resource_owned "libvirt-network" "$ISOLATED_NETWORK_NAME"; then
        isolated_network_is_active "$ISOLATED_NETWORK_NAME" || virsh net-start "$ISOLATED_NETWORK_NAME" >/dev/null
        virsh net-autostart "$ISOLATED_NETWORK_NAME" >/dev/null
        pass "Isolated libvirt network already exists and matches owned state"
        return 0
      fi
      if state_resource_intended "libvirt-network" "$ISOLATED_NETWORK_NAME"; then
        virsh net-autostart "$ISOLATED_NETWORK_NAME" >/dev/null
        isolated_network_is_active "$ISOLATED_NETWORK_NAME" || virsh net-start "$ISOLATED_NETWORK_NAME" >/dev/null
        state_record_resource "libvirt-network" "$ISOLATED_NETWORK_NAME" "recovered-created" yes "bridge=$ISOLATED_BRIDGE_NAME cidr=$ISOLATED_SUBNET"
        pass "Recovered deployment-owned isolated libvirt network after interrupted create"
        return 0
      fi
    fi
    fail "Libvirt network '$ISOLATED_NETWORK_NAME' already exists but is not a matching AutoDeploy-owned resource"
    return 1
  fi

  local xmlfile="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-isolated-network.xml"
  render_isolated_network_xml "$ISOLATED_NETWORK_NAME" "$ISOLATED_BRIDGE_NAME" "$ISOLATED_SUBNET" "$BRIDGE_IP" >"$xmlfile"
  chmod 0600 "$xmlfile"
  state_record_intent "libvirt-network" "$ISOLATED_NETWORK_NAME" defining "bridge=$ISOLATED_BRIDGE_NAME cidr=$ISOLATED_SUBNET"

  if ! virsh net-define "$xmlfile" >/dev/null; then
    return 1
  fi
  if ! virsh net-autostart "$ISOLATED_NETWORK_NAME" >/dev/null; then
    virsh net-undefine "$ISOLATED_NETWORK_NAME" >/dev/null 2>&1 || true
    state_record_resource "libvirt-network" "$ISOLATED_NETWORK_NAME" "removed-after-failure" no ""
    return 1
  fi
  if ! virsh net-start "$ISOLATED_NETWORK_NAME" >/dev/null; then
    virsh net-autostart "$ISOLATED_NETWORK_NAME" --disable >/dev/null 2>&1 || true
    virsh net-undefine "$ISOLATED_NETWORK_NAME" >/dev/null 2>&1 || true
    state_record_resource "libvirt-network" "$ISOLATED_NETWORK_NAME" "removed-after-failure" no ""
    return 1
  fi

  verify_isolated_network_definition "$ISOLATED_NETWORK_NAME" "$ISOLATED_BRIDGE_NAME" "$ISOLATED_SUBNET" "$BRIDGE_IP"
  isolated_network_is_active "$ISOLATED_NETWORK_NAME"
  state_record_resource "libvirt-network" "$ISOLATED_NETWORK_NAME" "created" yes "bridge=$ISOLATED_BRIDGE_NAME cidr=$ISOLATED_SUBNET"
  pass "Created isolated libvirt network '$ISOLATED_NETWORK_NAME' on '$ISOLATED_BRIDGE_NAME'"
}

isolated_network_rollback() {
  isolated_network_defaults
  if ! isolated_network_exists "$ISOLATED_NETWORK_NAME"; then return 0; fi
  if ! state_resource_owned "libvirt-network" "$ISOLATED_NETWORK_NAME"; then
    if state_resource_intended "libvirt-network" "$ISOLATED_NETWORK_NAME" &&
       verify_isolated_network_definition "$ISOLATED_NETWORK_NAME" "$ISOLATED_BRIDGE_NAME" "$ISOLATED_SUBNET" "$BRIDGE_IP"; then
      state_record_resource "libvirt-network" "$ISOLATED_NETWORK_NAME" recovered-created yes "rollback-adoption"
    else
      fail "Refusing to remove non-owned libvirt network '$ISOLATED_NETWORK_NAME'"
      return 1
    fi
  fi
  virsh net-destroy "$ISOLATED_NETWORK_NAME" >/dev/null 2>&1 || true
  virsh net-autostart "$ISOLATED_NETWORK_NAME" --disable >/dev/null 2>&1 || true
  virsh net-undefine "$ISOLATED_NETWORK_NAME" >/dev/null
  state_record_resource "libvirt-network" "$ISOLATED_NETWORK_NAME" "removed-by-rollback" "yes" ""
  pass "Removed AutoDeploy-owned isolated libvirt network '$ISOLATED_NETWORK_NAME'"
}

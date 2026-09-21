#!/usr/bin/env bash

INETSIM_DOMAIN_NAME="${INETSIM_DOMAIN_NAME:-cape-inetsim-appliance}"

choose_libvirt_storage_pool() {
  local p state xml typ avail path
  local -a ordered=()
  virsh pool-info default >/dev/null 2>&1 && ordered+=(default)
  while IFS= read -r p; do [[ -n "$p" && "$p" != default ]] && ordered+=("$p"); done < <(virsh pool-list --all --name 2>/dev/null)
  for p in "${ordered[@]}"; do
    state="$(virsh pool-info "$p" 2>/dev/null | awk -F: '/^State:/ {gsub(/^[ \t]+/,"",$2);print $2}')"
    [[ "$state" == running ]] || continue
    xml="$(virsh pool-dumpxml "$p" 2>/dev/null || true)"
    typ="$(python3 -c 'import sys,xml.etree.ElementTree as E; r=E.fromstring(sys.stdin.read()); print(r.get("type",""))' <<<"$xml" 2>/dev/null || true)"
    [[ "$typ" == dir ]] || continue
    path="$(python3 -c 'import sys,xml.etree.ElementTree as E; r=E.fromstring(sys.stdin.read()); x=r.find("./target/path"); print(x.text if x is not None else "")' <<<"$xml" 2>/dev/null || true)"
    [[ -n "$path" && -d "$path" ]] || continue
    avail="$(df -Pk "$path" | awk 'NR==2{print $4}')"
    [[ "$avail" =~ ^[0-9]+$ && "$avail" -ge 20971520 ]] || continue
    LIBVIRT_STORAGE_POOL="$p"
    LIBVIRT_STORAGE_PATH="$path"
    return 0
  done
  fail "No active directory libvirt storage pool with at least 20 GiB free was found"
  return 1
}

inject_qga_channel() {
  python3 -c '
import sys,xml.etree.ElementTree as ET
r=ET.fromstring(sys.stdin.read())
devices=r.find("devices")
if devices is None: raise SystemExit("domain XML has no devices")
for c in devices.findall("channel"):
    t=c.find("target")
    if t is not None and t.get("name")=="org.qemu.guest_agent.0":
        print(ET.tostring(r,encoding="unicode"))
        raise SystemExit
c=ET.SubElement(devices,"channel",{"type":"unix"})
ET.SubElement(c,"target",{"type":"virtio","name":"org.qemu.guest_agent.0"})
print(ET.tostring(r,encoding="unicode"))
'
}

inetsim_domain_macs() {
  virsh dumpxml "$INETSIM_DOMAIN_NAME" | python3 -c '
import sys,xml.etree.ElementTree as ET
r=ET.fromstring(sys.stdin.read())
for i in r.findall("./devices/interface"):
    s=i.find("source")
    m=i.find("mac")
    if s is not None:
        print((s.get("network") or "")+"|"+(m.get("address") if m is not None else ""))
'
}

inetsim_domain_matches_plan() {
  local xml
  xml="$(virsh dumpxml "$INETSIM_DOMAIN_NAME" 2>/dev/null)" || return 1
  python3 -c '
import os,sys,xml.etree.ElementTree as ET
disk,mgmt,isolated=sys.argv[1:]
r=ET.fromstring(sys.stdin.read())
files=[]
for d in r.findall("./devices/disk"):
    if d.get("device")!="disk": continue
    s=d.find("source")
    if s is not None and s.get("file"): files.append(os.path.realpath(s.get("file")))
if os.path.realpath(disk) not in files: raise SystemExit(1)
nets=[]
for i in r.findall("./devices/interface"):
    s=i.find("source")
    if s is not None and s.get("network"): nets.append(s.get("network"))
if nets.count(mgmt)!=1 or nets.count(isolated)!=1: raise SystemExit(1)
qga=False
for ch in r.findall("./devices/channel"):
    t=ch.find("target")
    if t is not None and t.get("name")=="org.qemu.guest_agent.0": qga=True
if not qga: raise SystemExit(1)
' "$INETSIM_DISK_PATH" "$MANAGEMENT_NETWORK_NAME" "$ISOLATED_NETWORK_NAME" <<<"$xml"
}

inetsim_copy_appliance_disk() {
  local artifact="$1"

  if [[ -z "${INETSIM_DISK_PATH:-}" ]]; then
    choose_libvirt_storage_pool
    INETSIM_DISK_PATH="$LIBVIRT_STORAGE_PATH/cape-inetsim-appliance-v1.qcow2"
  else
    [[ -n "${LIBVIRT_STORAGE_PATH:-}" ]] || LIBVIRT_STORAGE_PATH="$(dirname "$INETSIM_DISK_PATH")"
    if [[ -z "${LIBVIRT_STORAGE_POOL:-}" ]]; then
      local p path
      while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        path="$(virsh pool-dumpxml "$p" 2>/dev/null | python3 -c 'import sys,xml.etree.ElementTree as E
try: r=E.fromstring(sys.stdin.read())
except Exception: raise SystemExit
x=r.find("./target/path")
print(x.text if x is not None else "")' 2>/dev/null || true)"
        if [[ "$path" == "$LIBVIRT_STORAGE_PATH" ]]; then LIBVIRT_STORAGE_POOL="$p"; break; fi
      done < <(virsh pool-list --all --name 2>/dev/null)
    fi
  fi

  if [[ -e "$INETSIM_DISK_PATH" ]]; then
    if state_resource_owned disk "$INETSIM_DISK_PATH"; then
      qemu-img check "$INETSIM_DISK_PATH" >/dev/null
      return 0
    fi
    if state_resource_intended disk "$INETSIM_DISK_PATH"; then
      qemu-img check "$INETSIM_DISK_PATH" >/dev/null
      state_record_resource disk "$INETSIM_DISK_PATH" recovered-created yes "pool=${LIBVIRT_STORAGE_POOL:-unknown}"
      state_write_atomic
      pass "Recovered deployment-owned INetSim disk after interrupted create"
      return 0
    fi
    fail "INetSim target disk already exists but is not AutoDeploy-owned: $INETSIM_DISK_PATH"
    return 1
  fi

  [[ -d "$(dirname "$INETSIM_DISK_PATH")" ]] || { fail "INetSim disk directory is unavailable: $(dirname "$INETSIM_DISK_PATH")"; return 1; }
  local avail
  avail="$(df -Pk "$(dirname "$INETSIM_DISK_PATH")" | awk 'NR==2{print $4}')"
  [[ "$avail" =~ ^[0-9]+$ && "$avail" -ge 20971520 ]] || { fail "Less than 20 GiB free for INetSim appliance disk"; return 1; }

  state_write_atomic
  state_record_intent disk "$INETSIM_DISK_PATH" creating "pool=${LIBVIRT_STORAGE_POOL:-unknown}"
  rm -f "$INETSIM_DISK_PATH.part"
  qemu-img convert -p -O qcow2 "$artifact" "$INETSIM_DISK_PATH.part"
  qemu-img check "$INETSIM_DISK_PATH.part" >/dev/null
  mv "$INETSIM_DISK_PATH.part" "$INETSIM_DISK_PATH"
  chmod 0644 "$INETSIM_DISK_PATH"
  [[ -n "${LIBVIRT_STORAGE_POOL:-}" ]] && virsh pool-refresh "$LIBVIRT_STORAGE_POOL" >/dev/null 2>&1 || true
  state_record_resource disk "$INETSIM_DISK_PATH" created yes "pool=${LIBVIRT_STORAGE_POOL:-unknown}"
  state_write_atomic
}

inetsim_define_domain() {
  [[ -n "${MANAGEMENT_NETWORK_NAME:-}" ]] || { fail "Management libvirt network is unknown"; return 1; }

  if virsh dominfo "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1; then
    inetsim_domain_matches_plan || { fail "Existing domain $INETSIM_DOMAIN_NAME does not match deployment plan"; return 1; }
    if state_resource_owned domain "$INETSIM_DOMAIN_NAME"; then
      virsh autostart "$INETSIM_DOMAIN_NAME" >/dev/null
    elif state_resource_intended domain "$INETSIM_DOMAIN_NAME"; then
      virsh autostart "$INETSIM_DOMAIN_NAME" >/dev/null
      state_record_resource domain "$INETSIM_DOMAIN_NAME" recovered-created yes "disk=$INETSIM_DISK_PATH"
      pass "Recovered deployment-owned INetSim domain after interrupted create"
    else
      fail "Domain $INETSIM_DOMAIN_NAME exists but is not AutoDeploy-owned"
      return 1
    fi

    INETSIM_MANAGEMENT_MAC="$(inetsim_domain_macs | awk -F'|' -v n="$MANAGEMENT_NETWORK_NAME" '$1==n{print $2;exit}')"
    INETSIM_ISOLATED_MAC="$(inetsim_domain_macs | awk -F'|' -v n="$ISOLATED_NETWORK_NAME" '$1==n{print $2;exit}')"
    [[ -n "$INETSIM_MANAGEMENT_MAC" && -n "$INETSIM_ISOLATED_MAC" ]] || { fail "Could not identify appliance NIC MAC addresses"; return 1; }
    state_write_atomic
    return 0
  fi

  local raw="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-inetsim-domain.raw.xml"
  local xml="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-inetsim-domain.xml"
  virt-install --connect qemu:///system --name "$INETSIM_DOMAIN_NAME" --memory 4096 --vcpus 2 --import     --disk "path=$INETSIM_DISK_PATH,format=qcow2,bus=virtio"     --network "network=$MANAGEMENT_NETWORK_NAME,model=virtio"     --network "network=$ISOLATED_NETWORK_NAME,model=virtio"     --os-variant generic --graphics none --noautoconsole --print-xml >"$raw"
  inject_qga_channel <"$raw" >"$xml"

  state_record_intent domain "$INETSIM_DOMAIN_NAME" defining "disk=$INETSIM_DISK_PATH"
  if ! virsh define "$xml" >/dev/null; then return 1; fi
  if ! virsh autostart "$INETSIM_DOMAIN_NAME" >/dev/null; then
    virsh undefine "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
    state_record_resource domain "$INETSIM_DOMAIN_NAME" removed-after-failure no ""
    return 1
  fi
  inetsim_domain_matches_plan || { fail "Defined INetSim domain does not match deployment plan"; return 1; }

  state_record_resource domain "$INETSIM_DOMAIN_NAME" created yes "disk=$INETSIM_DISK_PATH"
  INETSIM_MANAGEMENT_MAC="$(inetsim_domain_macs | awk -F'|' -v n="$MANAGEMENT_NETWORK_NAME" '$1==n{print $2;exit}')"
  INETSIM_ISOLATED_MAC="$(inetsim_domain_macs | awk -F'|' -v n="$ISOLATED_NETWORK_NAME" '$1==n{print $2;exit}')"
  [[ -n "$INETSIM_MANAGEMENT_MAC" && -n "$INETSIM_ISOLATED_MAC" ]] || { fail "Could not identify appliance NIC MAC addresses"; return 1; }
  state_write_atomic
}

inetsim_configure_guest() {
  virsh start "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
  qga_wait "$INETSIM_DOMAIN_NAME" 180 || { fail "INetSim appliance QEMU Guest Agent did not come online"; return 1; }
  qga_exec_wait "$INETSIM_DOMAIN_NAME" /usr/local/sbin/cape-inetsim-guest-configure --management-mac "$INETSIM_MANAGEMENT_MAC" --isolated-mac "$INETSIM_ISOLATED_MAC" --ip "$INETSIM_IP/24"
  state_record_resource inetsim-guest "$INETSIM_DOMAIN_NAME" configured yes "ip=$INETSIM_IP mac=$INETSIM_ISOLATED_MAC"
  state_write_atomic
}

inetsim_verify_host() {
  python3 "$AUTODEPLOY_ROOT/tools/dns_probe.py" "$INETSIM_IP" "$INETSIM_IP" >/dev/null
  curl -fsS --max-time 5 "http://$INETSIM_IP/" >/dev/null
  curl -kfsS --max-time 5 "https://$INETSIM_IP/" >/dev/null
  pass "INetSim DNS, HTTP and HTTPS respond on $INETSIM_IP"
}

inetsim_vm_rollback() {
  if virsh dominfo "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1; then
    if ! state_resource_owned domain "$INETSIM_DOMAIN_NAME"; then
      if state_resource_intended domain "$INETSIM_DOMAIN_NAME" && inetsim_domain_matches_plan; then
        state_record_resource domain "$INETSIM_DOMAIN_NAME" recovered-created yes "rollback-adoption"
      else
        fail "Refusing to remove non-owned INetSim domain $INETSIM_DOMAIN_NAME"
        return 1
      fi
    fi
    virsh destroy "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
    virsh undefine "$INETSIM_DOMAIN_NAME" --nvram >/dev/null 2>&1 || virsh undefine "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
    state_record_resource domain "$INETSIM_DOMAIN_NAME" removed-by-rollback yes ""
  fi

  if [[ -n "${INETSIM_DISK_PATH:-}" ]]; then
    rm -f "$INETSIM_DISK_PATH.part" 2>/dev/null || true
  fi
  if [[ -n "${INETSIM_DISK_PATH:-}" && -e "$INETSIM_DISK_PATH" ]]; then
    if ! state_resource_owned disk "$INETSIM_DISK_PATH"; then
      if state_resource_intended disk "$INETSIM_DISK_PATH"; then
        qemu-img check "$INETSIM_DISK_PATH" >/dev/null || { fail "Intended INetSim disk is not a valid qcow2 image"; return 1; }
        state_record_resource disk "$INETSIM_DISK_PATH" recovered-created yes "rollback-adoption"
      else
        fail "Refusing to remove non-owned INetSim disk $INETSIM_DISK_PATH"
        return 1
      fi
    fi
    rm -f "$INETSIM_DISK_PATH"
    state_record_resource disk "$INETSIM_DISK_PATH" removed-by-rollback yes ""
  fi
}

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

inetsim_copy_appliance_disk() {
  local artifact="$1"
  choose_libvirt_storage_pool
  INETSIM_DISK_PATH="$LIBVIRT_STORAGE_PATH/cape-inetsim-appliance-v1.qcow2"
  if [[ -e "$INETSIM_DISK_PATH" ]]; then
    if state_resource_owned disk "$INETSIM_DISK_PATH"; then return 0; fi
    fail "INetSim target disk already exists but is not AutoDeploy-owned: $INETSIM_DISK_PATH"
    return 1
  fi
  qemu-img convert -p -O qcow2 "$artifact" "$INETSIM_DISK_PATH.part"
  qemu-img check "$INETSIM_DISK_PATH.part" >/dev/null
  mv "$INETSIM_DISK_PATH.part" "$INETSIM_DISK_PATH"
  chmod 0644 "$INETSIM_DISK_PATH"
  virsh pool-refresh "$LIBVIRT_STORAGE_POOL" >/dev/null 2>&1 || true
  state_record_resource disk "$INETSIM_DISK_PATH" created yes "pool=$LIBVIRT_STORAGE_POOL"
  state_write_atomic
}

inetsim_define_domain() {
  if virsh dominfo "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1; then
    state_resource_owned domain "$INETSIM_DOMAIN_NAME" || { fail "Domain $INETSIM_DOMAIN_NAME exists but is not AutoDeploy-owned"; return 1; }
    return 0
  fi
  [[ -n "${MANAGEMENT_NETWORK_NAME:-}" ]] || { fail "Management libvirt network is unknown"; return 1; }

  local raw="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-inetsim-domain.raw.xml"
  local xml="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-inetsim-domain.xml"
  virt-install --connect qemu:///system --name "$INETSIM_DOMAIN_NAME" --memory 4096 --vcpus 2 --import     --disk "path=$INETSIM_DISK_PATH,format=qcow2,bus=virtio"     --network "network=$MANAGEMENT_NETWORK_NAME,model=virtio"     --network "network=$ISOLATED_NETWORK_NAME,model=virtio"     --os-variant generic --graphics none --noautoconsole --print-xml >"$raw"
  inject_qga_channel <"$raw" >"$xml"

  virsh define "$xml" >/dev/null
  virsh autostart "$INETSIM_DOMAIN_NAME" >/dev/null
  state_record_resource domain "$INETSIM_DOMAIN_NAME" defined yes "disk=$INETSIM_DISK_PATH"

  INETSIM_MANAGEMENT_MAC="$(inetsim_domain_macs | awk -F'|' -v n="$MANAGEMENT_NETWORK_NAME" '$1==n{print $2;exit}')"
  INETSIM_ISOLATED_MAC="$(inetsim_domain_macs | awk -F'|' -v n="$ISOLATED_NETWORK_NAME" '$1==n{print $2;exit}')"
  [[ -n "$INETSIM_MANAGEMENT_MAC" && -n "$INETSIM_ISOLATED_MAC" ]] || { fail "Could not identify appliance NIC MAC addresses"; return 1; }
  state_write_atomic
}

qga_wait() {
  local dom="$1" timeout="${2:-180}" i
  for ((i=0;i<timeout;i+=2)); do
    virsh qemu-agent-command "$dom" '{"execute":"guest-ping"}' >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

qga_exec_wait() {
  local dom="$1" path="$2"
  shift 2
  local json pid status exited i args_json
  args_json="$(python3 - "$@" <<'PY'
import json,sys
print(json.dumps(sys.argv[1:]))
PY
)"
  json="$(python3 - "$path" "$args_json" <<'PY'
import json,sys
print(json.dumps({"execute":"guest-exec","arguments":{"path":sys.argv[1],"arg":json.loads(sys.argv[2]),"capture-output":True}}))
PY
)"
  pid="$(virsh qemu-agent-command "$dom" "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["return"]["pid"])')"

  for ((i=0;i<180;i++)); do
    status="$(virsh qemu-agent-command "$dom" "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}")"
    exited="$(python3 -c 'import json,sys; print(str(json.load(sys.stdin)["return"].get("exited",False)).lower())' <<<"$status")"
    if [[ "$exited" == true ]]; then
      python3 -c 'import base64,json,sys
r=json.load(sys.stdin)["return"]
if r.get("out-data"): sys.stdout.write(base64.b64decode(r["out-data"]).decode(errors="replace"))
if r.get("err-data"): sys.stderr.write(base64.b64decode(r["err-data"]).decode(errors="replace"))
raise SystemExit(r.get("exitcode",1))' <<<"$status"
      return $?
    fi
    sleep 1
  done
  return 124
}

inetsim_configure_guest() {
  virsh start "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
  qga_wait "$INETSIM_DOMAIN_NAME" 180 || { fail "INetSim appliance QEMU Guest Agent did not come online"; return 1; }
  qga_exec_wait "$INETSIM_DOMAIN_NAME" /usr/local/sbin/cape-inetsim-guest-configure --isolated-mac "$INETSIM_ISOLATED_MAC" --ip "$INETSIM_IP/24"
  state_record_resource inetsim-guest "$INETSIM_DOMAIN_NAME" configured yes "ip=$INETSIM_IP mac=$INETSIM_ISOLATED_MAC"
  state_set_phase appliance-configured
}

inetsim_verify_host() {
  python3 "$AUTODEPLOY_ROOT/tools/dns_probe.py" "$INETSIM_IP" "$INETSIM_IP" >/dev/null
  curl -fsS --max-time 5 "http://$INETSIM_IP/" >/dev/null
  pass "INetSim DNS and HTTP respond on $INETSIM_IP"
}

inetsim_vm_rollback() {
  if virsh dominfo "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 && state_resource_owned domain "$INETSIM_DOMAIN_NAME"; then
    virsh destroy "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
    virsh undefine "$INETSIM_DOMAIN_NAME" --nvram >/dev/null 2>&1 || virsh undefine "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
    state_record_resource domain "$INETSIM_DOMAIN_NAME" removed-by-rollback yes ""
  fi
  if [[ -n "${INETSIM_DISK_PATH:-}" && -e "$INETSIM_DISK_PATH" ]] && state_resource_owned disk "$INETSIM_DISK_PATH"; then
    rm -f "$INETSIM_DISK_PATH"
    state_record_resource disk "$INETSIM_DISK_PATH" removed-by-rollback yes ""
  fi
}

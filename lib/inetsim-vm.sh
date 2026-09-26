#!/usr/bin/env bash

INETSIM_DOMAIN_NAME="${INETSIM_DOMAIN_NAME:-cape-inetsim-appliance}"
INETSIM_MEMORY_MIB="${INETSIM_MEMORY_MIB:-2048}"

choose_libvirt_storage_pool() {
  local p state xml typ avail path
  if [[ -n "${LIBVIRT_STORAGE_POOL:-}" && -n "${LIBVIRT_STORAGE_PATH:-}" && -d "$LIBVIRT_STORAGE_PATH" ]]; then
    state="$(virsh pool-info "$LIBVIRT_STORAGE_POOL" 2>/dev/null | awk -F: '/^State:/ {gsub(/^[ \t]+/,"",$2);print $2}')"
    avail="$(df -Pk "$LIBVIRT_STORAGE_PATH" 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ "$state" == running && "$avail" =~ ^[0-9]+$ && "$avail" -ge 20971520 ]]; then
      return 0
    fi
    LIBVIRT_STORAGE_POOL=""
    LIBVIRT_STORAGE_PATH=""
  fi

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


INETSIM_GRAPHICS_CHANGED=no

inetsim_refresh_baked_gui_appliance() {
  local artifact new_disk old_disk state i
  state_resource_owned domain "$INETSIM_DOMAIN_NAME" || {
    fail "Refusing GUI appliance refresh because INetSim domain is not AutoDeploy-owned"
    return 1
  }
  state_resource_owned disk "$INETSIM_DISK_PATH" || {
    fail "Refusing GUI appliance refresh because INetSim disk is not AutoDeploy-owned"
    return 1
  }

  artifact="$(appliance_fetch "$APPLIANCE_MANIFEST")" || return 1
  new_disk="$INETSIM_DISK_PATH.gui-refresh-new"
  old_disk="$INETSIM_DISK_PATH.gui-refresh-old"

  rm -f "$new_disk" "$old_disk"
  info "Preparing verified GUI-ready INetSim appliance replacement"
  qemu-img convert -p -O qcow2 "$artifact" "$new_disk"
  qemu-img check "$new_disk" >/dev/null || {
    rm -f "$new_disk"
    fail "Prepared GUI-ready INetSim appliance disk failed qcow2 integrity check"
    return 1
  }

  virsh shutdown "$INETSIM_DOMAIN_NAME" --mode agent >/dev/null 2>&1 || true
  for ((i=0;i<60;i++)); do
    state="$(virsh domstate "$INETSIM_DOMAIN_NAME" 2>/dev/null | tr -d '\r' || true)"
    [[ "$state" == "shut off" ]] && break
    sleep 1
  done
  state="$(virsh domstate "$INETSIM_DOMAIN_NAME" 2>/dev/null | tr -d '\r' || true)"
  [[ "$state" == "shut off" ]] || virsh destroy "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true

  mv "$INETSIM_DISK_PATH" "$old_disk"
  if ! mv "$new_disk" "$INETSIM_DISK_PATH"; then
    mv "$old_disk" "$INETSIM_DISK_PATH" 2>/dev/null || true
    fail "Could not activate GUI-ready INetSim appliance disk"
    return 1
  fi

  if ! virsh start "$INETSIM_DOMAIN_NAME" >/dev/null ||
     ! qga_wait "$INETSIM_DOMAIN_NAME" 240 ||
     ! qga_exec_wait "$INETSIM_DOMAIN_NAME" /usr/bin/test -f /etc/cape-inetsim-gui-v1 >/dev/null 2>&1; then
    virsh destroy "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
    rm -f "$INETSIM_DISK_PATH"
    mv "$old_disk" "$INETSIM_DISK_PATH"
    virsh start "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
    qga_wait "$INETSIM_DOMAIN_NAME" 120 >/dev/null 2>&1 || true
    fail "GUI-ready appliance refresh failed validation; original INetSim disk was restored"
    return 1
  fi

  rm -f "$old_disk"
  state_record_resource inetsim-gui-refresh "$INETSIM_DOMAIN_NAME" replaced yes "verified-release-appliance"
  state_write_atomic
  pass "Refreshed INetSim appliance to verified GUI-ready release image"
}

inetsim_ensure_graphics_console() {
  local raw="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-inetsim-graphics.xml"
  local current
  INETSIM_GRAPHICS_CHANGED=no

  current="$(virsh dumpxml --inactive "$INETSIM_DOMAIN_NAME" 2>/dev/null)" || {
    fail "Could not read persistent INetSim domain XML for graphical-console setup"
    return 1
  }

  if python3 -c '
import sys,xml.etree.ElementTree as ET
r=ET.fromstring(sys.stdin.read())
g=r.find("./devices/graphics")
v=r.find("./devices/video/model")
ok=(g is not None and g.get("type")=="spice" and v is not None and v.get("type")=="qxl")
raise SystemExit(0 if ok else 1)
' <<<"$current"; then
    return 0
  fi

  python3 -c '
import sys,xml.etree.ElementTree as ET
out=sys.argv[1]
r=ET.fromstring(sys.stdin.read())
d=r.find("devices")
if d is None:
    raise SystemExit("domain XML has no devices")
for x in list(d.findall("graphics")):
    d.remove(x)
for x in list(d.findall("video")):
    d.remove(x)
g=ET.SubElement(d,"graphics",{"type":"spice","autoport":"yes","listen":"127.0.0.1"})
ET.SubElement(g,"listen",{"type":"address","address":"127.0.0.1"})
v=ET.SubElement(d,"video")
ET.SubElement(v,"model",{"type":"qxl","ram":"65536","vram":"65536","vgamem":"16384","heads":"1","primary":"yes"})
ET.indent(r,space="  ")
ET.ElementTree(r).write(out,encoding="unicode")
' "$raw" <<<"$current"

  virsh define "$raw" >/dev/null || {
    fail "Could not add persistent SPICE/QXL graphical console to INetSim appliance"
    return 1
  }

  INETSIM_GRAPHICS_CHANGED=yes
  state_record_resource domain-graphics "$INETSIM_DOMAIN_NAME" configured yes "type=spice video=qxl listen=127.0.0.1"
  state_write_atomic
  pass "Configured persistent SPICE/QXL graphical console for INetSim appliance"
}

inetsim_enable_gui_guest() {
  local remote='/tmp/cape-inetsim-gui-enable'
  local guest_log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-inetsim-gui-enable.log"
  local installed=no restart=no

  inetsim_ensure_graphics_console
  [[ "$INETSIM_GRAPHICS_CHANGED" == yes ]] && restart=yes

  virsh start "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
  qga_wait "$INETSIM_DOMAIN_NAME" 240 || {
    fail "INetSim appliance QEMU Guest Agent did not come online for GUI setup"
    return 1
  }

  if ! qga_exec_wait "$INETSIM_DOMAIN_NAME" /usr/bin/test -f /etc/cape-inetsim-gui-v1 >/dev/null 2>&1; then
    info "Existing INetSim appliance predates the baked graphical desktop; refreshing only the AutoDeploy-owned appliance"
    inetsim_refresh_baked_gui_appliance || return 1
    inetsim_configure_guest || return 1
    inetsim_verify_host || return 1
    restart=yes
  fi

  if qga_exec_wait "$INETSIM_DOMAIN_NAME" /usr/bin/test -f /etc/cape-inetsim-gui-v1 >/dev/null 2>&1; then
    pass "INetSim Ubuntu graphical desktop already installed"
  else
    : >"$guest_log"
    chmod 0600 "$guest_log"
    local upload_ok=no upload_attempt helper_b64 helper_sha remote_sha
    for upload_attempt in 1 2 3 4 5; do
      if qga_file_write "$INETSIM_DOMAIN_NAME" "$AUTODEPLOY_ROOT/appliance/gui-enable.sh" "$remote" >>"$guest_log" 2>&1; then
        upload_ok=yes
        break
      fi
      printf 'GUI helper guest-file upload attempt %d failed; waiting for QGA recovery\n' "$upload_attempt" >>"$guest_log"
      qga_wait "$INETSIM_DOMAIN_NAME" 30 >/dev/null 2>&1 || true
      sleep "$upload_attempt"
    done

    # Some QGA builds support guest-exec reliably while guest-file-open/write is
    # unavailable or intermittently broken. The helper is small, so use a
    # checksum-verified guest-exec/base64 fallback rather than weakening the
    # repair gate or requiring manual guest access.
    if [[ "$upload_ok" != yes ]]; then
      helper_b64="$(base64 -w0 "$AUTODEPLOY_ROOT/appliance/gui-enable.sh")"
      helper_sha="$(sha256sum "$AUTODEPLOY_ROOT/appliance/gui-enable.sh" | awk '{print $1}')"
      if qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/bash -c \
        "printf '%s' '$helper_b64' | /usr/bin/base64 -d > '$remote' && /bin/chmod 0700 '$remote'" \
        >>"$guest_log" 2>&1; then
        remote_sha="$(qga_exec_wait "$INETSIM_DOMAIN_NAME" /usr/bin/sha256sum "$remote" 2>>"$guest_log" | awk '{print $1}')"
        if [[ "$remote_sha" == "$helper_sha" ]]; then
          upload_ok=yes
          printf 'GUI helper uploaded through checksum-verified guest-exec fallback\n' >>"$guest_log"
        else
          printf 'GUI helper guest-exec checksum mismatch: expected=%s actual=%s\n' "$helper_sha" "$remote_sha" >>"$guest_log"
        fi
      fi
    fi

    if [[ "$upload_ok" != yes ]]; then
      fail "Could not upload GUI enable helper through QGA guest-file or guest-exec fallback; log captured at $guest_log"
      return 1
    fi

    info "Installing lightweight Ubuntu XFCE desktop inside INetSim appliance; this may take several minutes"
    if ! QGA_EXEC_WAIT_SECONDS=1500 qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/bash -c       "/bin/bash '$remote' >/var/log/cape-inetsim-gui-enable.log 2>&1" >>"$guest_log" 2>&1; then
      qga_file_read "$INETSIM_DOMAIN_NAME" /var/log/cape-inetsim-gui-enable.log "$guest_log.guest" >/dev/null 2>&1 || true
      fail "INetSim Ubuntu graphical desktop installation failed; log captured at $guest_log"
      return 1
    fi
    qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/rm -f "$remote" >/dev/null 2>&1 || true
    installed=yes
    restart=yes
    state_record_resource inetsim-gui "$INETSIM_DOMAIN_NAME" installed yes "desktop=xfce display=spice/qxl"
    state_write_atomic
    pass "Installed lightweight Ubuntu XFCE graphical desktop in INetSim appliance"
  fi

  if [[ "$restart" == yes ]]; then
    info "Restarting INetSim appliance once to activate its graphical console"
    virsh shutdown "$INETSIM_DOMAIN_NAME" --mode agent >/dev/null 2>&1 || true
    local i state
    for ((i=0;i<60;i++)); do
      state="$(virsh domstate "$INETSIM_DOMAIN_NAME" 2>/dev/null | tr -d '\r' || true)"
      [[ "$state" == "shut off" ]] && break
      sleep 1
    done
    state="$(virsh domstate "$INETSIM_DOMAIN_NAME" 2>/dev/null | tr -d '\r' || true)"
    if [[ "$state" != "shut off" ]]; then
      virsh destroy "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
    fi
    virsh start "$INETSIM_DOMAIN_NAME" >/dev/null
    qga_wait "$INETSIM_DOMAIN_NAME" 240 || {
      fail "INetSim appliance did not return after graphical-console restart"
      return 1
    }
  fi

  qga_exec_wait "$INETSIM_DOMAIN_NAME" /usr/bin/test -f /etc/cape-inetsim-gui-v1 >/dev/null 2>&1 || {
    fail "INetSim graphical desktop marker is missing after setup"
    return 1
  }
  qga_exec_wait "$INETSIM_DOMAIN_NAME" /usr/bin/systemctl is-active --quiet lightdm.service >/dev/null 2>&1 || {
    fail "INetSim graphical display manager is not active after setup"
    return 1
  }
  local display_uri
  display_uri="$(virsh domdisplay "$INETSIM_DOMAIN_NAME" 2>/dev/null || true)"
  [[ "$display_uri" == spice://* ]] || {
    fail "INetSim appliance has no active SPICE graphical display"
    return 1
  }
  pass "INetSim Ubuntu graphical interface is available through virt-manager"
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
  virt-install --connect qemu:///system --name "$INETSIM_DOMAIN_NAME" --memory "$INETSIM_MEMORY_MIB" --vcpus 2 --import     --disk "path=$INETSIM_DISK_PATH,format=qcow2,bus=virtio"     --network "network=$MANAGEMENT_NETWORK_NAME,model=virtio"     --network "network=$ISOLATED_NETWORK_NAME,model=virtio"     --os-variant generic --graphics "spice,listen=127.0.0.1" --video qxl --noautoconsole --print-xml >"$raw"
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

inetsim_capture_guest_diagnostics() {
  local out="$AD_LOG_ROOT/${DEPLOYMENT_ID}-inetsim-guest-diagnostics.txt"
  qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/sh -c '
set +e
echo "=== date ==="; date -Is
echo "=== addresses ==="; ip -br addr
echo "=== routes ==="; ip -4 route; ip -6 route
echo "=== netplan ==="; cat /etc/netplan/90-cape-inetsim.yaml 2>/dev/null
echo "=== listeners ==="; ss -lnupt
echo "=== inetsim status ==="; systemctl status inetsim.service --no-pager -l
echo "=== inetsim journal ==="; journalctl -u inetsim.service -n 120 --no-pager
' >"$out" 2>&1 || true
}

inetsim_configure_guest() {
  local guest_script='/tmp/cape-inetsim-guest-configure'
  local baked_script='/usr/local/sbin/cape-inetsim-guest-configure'
  local guest_log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-inetsim-guest-configure.log"
  local selected_script="" transport="" current_hash="" baked_hash=""

  virsh start "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
  qga_wait "$INETSIM_DOMAIN_NAME" 240 || { fail "INetSim appliance QEMU Guest Agent did not come online"; return 1; }

  # Create the trace before attempting transport so a QGA file-copy failure is
  # preserved for the automatic collector instead of disappearing in rollback.
  : >"$guest_log"
  chmod 0600 "$guest_log"
  current_hash="$(sha256sum "$AUTODEPLOY_ROOT/appliance/guest-configure.sh" | awk '{print $1}')"

  # Prefer the configurator shipped by the current immutable runtime bundle.
  # Some qemu-guest-agent policies expose guest-exec but deny guest-file-* RPCs.
  # In that case, safely fall back only to a byte-identical configurator baked
  # into the checksum-pinned appliance produced from the same release source.
  if qga_file_write "$INETSIM_DOMAIN_NAME" "$AUTODEPLOY_ROOT/appliance/guest-configure.sh" "$guest_script" >>"$guest_log" 2>&1; then
    selected_script="$guest_script"
    transport="qga-file-write"
    printf 'CONFIGURATOR_TRANSPORT=%s\n' "$transport" >>"$guest_log"
  else
    printf 'QGA guest-file transport unavailable; checking baked configurator identity.\n' >>"$guest_log"
    baked_hash="$(qga_exec_wait "$INETSIM_DOMAIN_NAME" /usr/bin/sha256sum "$baked_script" 2>>"$guest_log" | awk 'NF {print $1; exit}' || true)"
    if [[ ! "$baked_hash" =~ ^[0-9a-f]{64}$ || "$baked_hash" != "$current_hash" ]]; then
      printf 'EXPECTED_CONFIGURATOR_SHA256=%s\n' "$current_hash" >>"$guest_log"
      printf 'BAKED_CONFIGURATOR_SHA256=%s\n' "${baked_hash:-unavailable}" >>"$guest_log"
      inetsim_capture_guest_diagnostics
      fail "Could not upload the current INetSim guest configurator and the baked configurator could not be proven byte-identical to this release"
      return 1
    fi
    selected_script="$baked_script"
    transport="baked-release-match"
    printf 'CONFIGURATOR_TRANSPORT=%s\n' "$transport" >>"$guest_log"
    printf 'CONFIGURATOR_SHA256=%s\n' "$current_hash" >>"$guest_log"
  fi

  local -a configure_args=(
    /bin/bash -x "$selected_script"
    --management-mac "$INETSIM_MANAGEMENT_MAC"
    --isolated-mac "$INETSIM_ISOLATED_MAC"
    --ip "$INETSIM_IP/24"
    --gateway "$BRIDGE_IP"
  )
  local client_ip
  while IFS= read -r client_ip; do
    [[ -n "$client_ip" ]] && configure_args+=(--client-ip "$client_ip")
  done < <(python3 - "${CAPE_TARGETS_JSON:-[]}" <<'PY'
import json,sys
try: a=json.loads(sys.argv[1])
except Exception: a=[]
for d in a:
    ip=str(d.get("ip") or "")
    if ip:
        print(ip)
PY
)

  if ! qga_exec_wait "$INETSIM_DOMAIN_NAME" "${configure_args[@]}" >>"$guest_log" 2>&1; then
    inetsim_capture_guest_diagnostics
    fail "INetSim guest configuration failed; command trace and guest diagnostics were captured automatically"
    return 1
  fi

  qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/rm -f "$guest_script" >/dev/null 2>&1 || true
  state_record_resource inetsim-guest "$INETSIM_DOMAIN_NAME" configured yes "ip=$INETSIM_IP mac=$INETSIM_ISOLATED_MAC transport=$transport log=$guest_log"
  state_write_atomic
}

inetsim_verify_host() {
  local verify_log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-inetsim-host-verify.log"
  : >"$verify_log"
  chmod 0600 "$verify_log"

  qga_wait "$INETSIM_DOMAIN_NAME" 30 || {
    printf 'qga_wait=failed\n' >>"$verify_log"
    fail "INetSim appliance QEMU Guest Agent is unavailable during verification"
    return 1
  }
  printf 'qga_wait=ok\n' >>"$verify_log"

  local runtime
  if ! runtime="$(qga_exec_wait "$INETSIM_DOMAIN_NAME" /bin/sh -c '
set -eu
printf "ipv4_forward=%s\\n" "$(sysctl -n net.ipv4.ip_forward)"
printf "ipv6_forward=%s\\n" "$(sysctl -n net.ipv6.conf.all.forwarding)"
printf "default4=%s\\n" "$(ip -4 route show default | wc -l)"
printf "default6=%s\\n" "$(ip -6 route show default | wc -l)"
' 2>>"$verify_log")"; then
    printf 'runtime_query=failed\n' >>"$verify_log"
    inetsim_capture_guest_diagnostics
    fail "Could not verify INetSim appliance runtime network isolation"
    return 1
  fi
  printf '%s\n' "$runtime" >>"$verify_log"

  grep -Fxq 'ipv4_forward=0' <<<"$runtime" || { inetsim_capture_guest_diagnostics; fail "INetSim appliance IPv4 forwarding is enabled"; return 1; }
  grep -Fxq 'ipv6_forward=0' <<<"$runtime" || { inetsim_capture_guest_diagnostics; fail "INetSim appliance IPv6 forwarding is enabled"; return 1; }
  grep -Eq '^default4=(0|1)$' <<<"$runtime" || { inetsim_capture_guest_diagnostics; fail "INetSim appliance has more than one IPv4 default route"; return 1; }
  grep -Fxq 'default6=0' <<<"$runtime" || { inetsim_capture_guest_diagnostics; fail "INetSim appliance unexpectedly has an IPv6 default route"; return 1; }

  local ready=no i dns_rc http_rc https_rc
  for ((i=0;i<30;i++)); do
    if python3 "$AUTODEPLOY_ROOT/tools/dns_probe.py" "$INETSIM_IP" "$INETSIM_IP" >/dev/null 2>&1; then dns_rc=0; else dns_rc=$?; fi
    if curl -fsS --max-time 3 "http://$INETSIM_IP/" >/dev/null 2>&1; then http_rc=0; else http_rc=$?; fi
    if curl -kfsS --max-time 3 "https://$INETSIM_IP/" >/dev/null 2>&1; then https_rc=0; else https_rc=$?; fi
    printf 'probe_attempt=%s dns_rc=%s http_rc=%s https_rc=%s\n' "$((i+1))" "$dns_rc" "$http_rc" "$https_rc" >>"$verify_log"
    if [[ "$dns_rc" -eq 0 && "$http_rc" -eq 0 && "$https_rc" -eq 0 ]]; then
      ready=yes
      break
    fi
    sleep 1
  done
  if [[ "$ready" != yes ]]; then
    inetsim_capture_guest_diagnostics
    fail "INetSim DNS/HTTP/HTTPS did not become reachable from the CAPE host"
    return 1
  fi
  pass "INetSim DNS/HTTP/HTTPS respond and runtime forwarding isolation is enforced on $INETSIM_IP"
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

  # Guest configuration ownership is logically removed with the appliance
  # domain. Close it even when a prior rollback attempt already removed the VM.
  if state_resource_owned inetsim-guest "$INETSIM_DOMAIN_NAME"; then
    if virsh dominfo "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1; then
      fail "INetSim domain $INETSIM_DOMAIN_NAME still exists after rollback removal"
      return 1
    fi
    state_record_resource inetsim-guest "$INETSIM_DOMAIN_NAME" removed-by-rollback yes "domain-absent"
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

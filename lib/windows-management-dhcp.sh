#!/usr/bin/env bash

windows_management_dhcp_backup_path() {
  local slug
  slug="$(ad_safe_token "$MANAGEMENT_NETWORK_NAME-$WINDOWS_MANAGEMENT_MAC")"
  printf '%s/windows-management-dhcp-%s.xml\n' "$AD_BACKUP_ROOT/$DEPLOYMENT_ID" "$slug"
}

windows_management_network_is_active() {
  local text
  text="$(virsh net-info "$MANAGEMENT_NETWORK_NAME" 2>/dev/null)" || return 1
  grep -Eq '^Active:[[:space:]]+yes' <<<"$text"
}

windows_management_dhcp_host_xml() {
  local xml
  xml="$(virsh net-dumpxml "$MANAGEMENT_NETWORK_NAME" 2>/dev/null)" || return 1
  python3 -c '
import sys,xml.etree.ElementTree as ET
mac=sys.argv[1].lower()
try:
    root=ET.fromstring(sys.stdin.read())
except Exception:
    raise SystemExit(2)
hits=[]
for h in root.findall("./ip/dhcp/host"):
    if (h.get("mac") or "").lower()==mac and h.get("ip"):
        hits.append(h)
if len(hits)>1:
    raise SystemExit(3)
if hits:
    print(ET.tostring(hits[0],encoding="unicode"))
' "$WINDOWS_MANAGEMENT_MAC" <<<"$xml"
}

windows_management_dhcp_host_ip() {
  local xml="$1"
  python3 -c '
import sys,xml.etree.ElementTree as ET
try:
    h=ET.fromstring(sys.stdin.read())
except Exception:
    raise SystemExit(1)
print(h.get("ip") or "")
' <<<"$xml"
}

windows_management_dhcp_desired_xml() {
  local old="$1"
  python3 -c '
import sys,xml.etree.ElementTree as ET
mac,ip,label=sys.argv[1:]
text=sys.stdin.read().strip()
h=ET.fromstring(text) if text else ET.Element("host")
h.set("mac",mac.lower())
h.set("ip",ip)
if label and not h.get("name"):
    h.set("name",label)
print(ET.tostring(h,encoding="unicode"))
' "$WINDOWS_MANAGEMENT_MAC" "$CAPE_MACHINE_IP" "$CAPE_MACHINE_LABEL" <<<"$old"
}

windows_management_dhcp_ip_conflict() {
  local xml
  xml="$(virsh net-dumpxml "$MANAGEMENT_NETWORK_NAME" 2>/dev/null)" || return 2
  python3 -c '
import sys,xml.etree.ElementTree as ET
ip,mac=sys.argv[1:]
try:
    root=ET.fromstring(sys.stdin.read())
except Exception:
    raise SystemExit(2)
for h in root.findall("./ip/dhcp/host"):
    if h.get("ip")==ip and (h.get("mac") or "").lower()!=mac.lower():
        print((h.get("mac") or "unknown")+"|"+(h.get("name") or ""))
        raise SystemExit(0)
raise SystemExit(1)
' "$CAPE_MACHINE_IP" "$WINDOWS_MANAGEMENT_MAC" <<<"$xml"
}

windows_management_dhcp_update() {
  local command="$1" xml="$2"
  local -a args=(--config)
  if windows_management_network_is_active; then
    args+=(--live)
  fi
  virsh net-update "$MANAGEMENT_NETWORK_NAME" "$command" ip-dhcp-host "$xml" "${args[@]}" >/dev/null
}

windows_management_dhcp_verify_expected() {
  local host
  host="$(windows_management_dhcp_host_xml)" || return 1
  [[ -n "$host" ]] || return 1
  [[ "$(windows_management_dhcp_host_ip "$host")" == "$CAPE_MACHINE_IP" ]]
}

windows_management_dhcp_align_if_needed() {
  [[ "$(virsh domstate "$DOMAIN" 2>/dev/null | xargs)" == "shut off" ]] || {
    fail "Windows management DHCP alignment requires the analysis VM to be shut off"
    return 1
  }

  local old old_ip desired backup conflict rc
  old="$(windows_management_dhcp_host_xml)" || {
    fail "Could not inspect management DHCP reservation for $DOMAIN"
    return 1
  }

  # No MAC-specific DHCP reservation means the guest may be statically
  # addressed. Do not invent host network policy in that case.
  [[ -n "$old" ]] || return 0

  old_ip="$(windows_management_dhcp_host_ip "$old")"
  [[ -n "$old_ip" ]] || {
    fail "Existing management DHCP reservation for $DOMAIN has no IPv4 address"
    return 1
  }
  [[ "$old_ip" != "$CAPE_MACHINE_IP" ]] || return 0

  if conflict="$(windows_management_dhcp_ip_conflict)"; then
    rc=0
  else
    rc=$?
  fi
  if [[ "$rc" -eq 0 ]]; then
    fail "CAPE management IP $CAPE_MACHINE_IP is already reserved to another MAC on $MANAGEMENT_NETWORK_NAME ($conflict)"
    return 1
  fi
  [[ "$rc" -eq 1 ]] || {
    fail "Could not validate management DHCP conflicts on $MANAGEMENT_NETWORK_NAME"
    return 1
  }

  backup="$(windows_management_dhcp_backup_path)"
  install -d -m 0700 "$(dirname "$backup")"
  printf '%s\n' "$old" >"$backup"
  chmod 0600 "$backup"
  desired="$(windows_management_dhcp_desired_xml "$old")"

  state_record_intent management-dhcp-host "$MANAGEMENT_NETWORK_NAME:$WINDOWS_MANAGEMENT_MAC" applying \
    "old_ip=$old_ip expected_ip=$CAPE_MACHINE_IP backup=$backup"

  windows_management_dhcp_update delete "$old" || {
    fail "Could not remove stale DHCP reservation $old_ip for $DOMAIN"
    return 1
  }

  if ! windows_management_dhcp_update add-last "$desired"; then
    windows_management_dhcp_update add-last "$old" >/dev/null 2>&1 || true
    fail "Could not install CAPE-aligned DHCP reservation $CAPE_MACHINE_IP for $DOMAIN"
    return 1
  fi

  windows_management_dhcp_verify_expected || {
    fail "Management DHCP reservation did not verify after alignment for $DOMAIN"
    return 1
  }

  state_record_resource management-dhcp-host "$MANAGEMENT_NETWORK_NAME:$WINDOWS_MANAGEMENT_MAC" aligned yes \
    "old_ip=$old_ip expected_ip=$CAPE_MACHINE_IP backup=$backup"
  state_write_atomic
  pass "Aligned management DHCP reservation for $DOMAIN: $old_ip -> $CAPE_MACHINE_IP"
}

windows_management_dhcp_restore_if_owned() {
  state_resource_owned management-dhcp-host "$MANAGEMENT_NETWORK_NAME:$WINDOWS_MANAGEMENT_MAC" || return 0

  local current backup old
  current="$(windows_management_dhcp_host_xml)" || {
    fail "Could not inspect aligned management DHCP reservation during rollback for $DOMAIN"
    return 1
  }

  windows_management_dhcp_verify_expected || {
    fail "Management DHCP reservation changed externally; refusing rollback overwrite for $DOMAIN"
    return 1
  }

  backup="$(windows_management_dhcp_backup_path)"
  [[ -s "$backup" ]] || {
    fail "Management DHCP backup is missing for $DOMAIN"
    return 1
  }
  old="$(cat "$backup")"

  windows_management_dhcp_update delete "$current" || return 1
  if ! windows_management_dhcp_update add-last "$old"; then
    windows_management_dhcp_update add-last "$current" >/dev/null 2>&1 || true
    fail "Could not restore original management DHCP reservation for $DOMAIN"
    return 1
  fi

  state_record_resource management-dhcp-host "$MANAGEMENT_NETWORK_NAME:$WINDOWS_MANAGEMENT_MAC" restored yes "backup=$backup"
  state_write_atomic
  pass "Restored original management DHCP reservation for $DOMAIN"
}

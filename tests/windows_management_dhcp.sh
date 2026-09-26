#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/windows-management-dhcp.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export NET_XML="$TMP/network.xml"

cat >"$NET_XML" <<'EOF'
<network>
  <name>default</name>
  <ip address="192.168.122.1" netmask="255.255.255.0">
    <dhcp>
      <host mac="52:54:00:aa:bb:cc" name="win7" ip="192.168.122.195"/>
      <host mac="52:54:00:11:22:33" name="other" ip="192.168.122.150"/>
    </dhcp>
  </ip>
</network>
EOF

MANAGEMENT_NETWORK_NAME=default
WINDOWS_MANAGEMENT_MAC=52:54:00:aa:bb:cc
CAPE_MACHINE_IP=192.168.122.186
CAPE_MACHINE_LABEL=win7
DOMAIN=win7
DEPLOYMENT_ID=test-dhcp
AD_BACKUP_ROOT="$TMP/backups"

state_write_atomic(){ :; }
state_record_intent(){ :; }
state_resource_owned(){
  local key="$1:$2"
  [[ "$(printf '%s' "$OWNED_KEYS" | grep -Fxc "$key" || true)" -gt 0 ]]
}
OWNED_KEYS=""
state_record_resource(){
  local kind="$1" name="$2" action="$3" created="$4"
  local key="$kind:$name"
  case "$action" in
    aligned)
      if [[ "$created" == yes ]]; then
        OWNED_KEYS="$(printf '%s\n%s\n' "$OWNED_KEYS" "$key" | sed '/^$/d' | sort -u)"
      fi
      ;;
    restored)
      OWNED_KEYS="$(printf '%s\n' "$OWNED_KEYS" | grep -Fxv "$key" || true)"
      ;;
  esac
}
pass(){ :; }
fail(){ printf '[FAIL] %s\n' "$*" >&2; }

virsh(){
  local op="$1"
  shift
  case "$op" in
    domstate)
      echo "shut off"
      ;;
    net-info)
      cat <<'EOF'
Name: default
UUID: test
Active: yes
Persistent: yes
Autostart: yes
Bridge: virbr0
EOF
      ;;
    net-dumpxml)
      cat "$NET_XML"
      ;;
    net-update)
      local network="$1" command="$2" section="$3" snippet="$4"
      [[ "$network" == default && "$section" == ip-dhcp-host ]]
      python3 - "$NET_XML" "$command" "$snippet" <<'PY'
import sys,xml.etree.ElementTree as ET
path,command,snippet=sys.argv[1:]
root=ET.parse(path).getroot()
dhcp=root.find("./ip/dhcp")
if dhcp is None:
    raise SystemExit(2)
want=ET.fromstring(snippet)
if command=="delete":
    hit=None
    for h in dhcp.findall("host"):
        if (h.get("mac") or "").lower()==(want.get("mac") or "").lower() and h.get("ip")==want.get("ip"):
            hit=h
            break
    if hit is None:
        raise SystemExit(3)
    dhcp.remove(hit)
elif command=="add-last":
    for h in dhcp.findall("host"):
        if (h.get("mac") or "").lower()==(want.get("mac") or "").lower():
            raise SystemExit(4)
    dhcp.append(want)
else:
    raise SystemExit(5)
ET.ElementTree(root).write(path,encoding="unicode")
PY
      ;;
    *)
      return 1
      ;;
  esac
}

# Exact host mismatch is aligned to CAPE's configured management IP.
windows_management_dhcp_align_if_needed
[[ "$(windows_management_dhcp_host_ip "$(windows_management_dhcp_host_xml)")" == 192.168.122.186 ]]
state_resource_owned management-dhcp-host "default:52:54:00:aa:bb:cc"
grep -Fq '192.168.122.195' "$(windows_management_dhcp_backup_path)"

# Rollback restores the exact pre-deployment reservation.
windows_management_dhcp_restore_if_owned
[[ "$(windows_management_dhcp_host_ip "$(windows_management_dhcp_host_xml)")" == 192.168.122.195 ]]
! state_resource_owned management-dhcp-host "default:52:54:00:aa:bb:cc"

# A target IP already reserved to another MAC must safe-stop without mutation.
python3 - "$NET_XML" <<'PY'
import sys,xml.etree.ElementTree as ET
p=sys.argv[1]
t=ET.parse(p); r=t.getroot(); d=r.find("./ip/dhcp")
ET.SubElement(d,"host",{"mac":"52:54:00:de:ad:be","name":"conflict","ip":"192.168.122.186"})
t.write(p,encoding="unicode")
PY
set +e
windows_management_dhcp_align_if_needed >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]]
[[ "$(windows_management_dhcp_host_ip "$(windows_management_dhcp_host_xml)")" == 192.168.122.195 ]]

grep -Fq 'windows-management-dhcp.sh' "$ROOT/install"
! grep -Fq 'windows_management_dhcp_align_if_needed' "$ROOT/lib/deploy.sh"
grep -Fq 'management-dhcp-host' "$ROOT/lib/rollback.sh"
grep -Fq 'windows_management_dhcp_restore_if_owned' "$ROOT/lib/windows-vm.sh"

echo '[PASS] legacy DHCP alignment is rollback-safe but route-separated deployment leaves management DHCP untouched'

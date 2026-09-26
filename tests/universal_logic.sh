#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/cape.sh"
source "$ROOT/lib/targets.sh"
source "$ROOT/lib/libvirt.sh"
source "$ROOT/lib/network.sh"

CAPE_MACHINE_RECORDS=(
  '{"section":"cape1","label":"cape1","ip":"192.168.122.105","snapshot":"old"}'
  '{"section":"win10","label":"win10","ip":"192.168.122.100","snapshot":"snapshot1"}'
)
LIBVIRT_DOMAINS=(win10)
REQUESTED_MACHINE=""
DISCOVERY_ERRORS=()
SELECTED_MACHINE_JSON=""
auto_select_cape_machine
[[ "$CAPE_MACHINE_SECTION" == "win10" ]]

CAPE_MACHINE_RECORDS=(
  '{"section":"cape1","label":"cape1","ip":"192.168.122.105","snapshot":"old"}'
  '{"section":"cuckoo1","label":"cuckoo1","ip":"192.168.122.100","snapshot":"snap2"}'
)
LIBVIRT_DOMAINS=(cuckoo1 ubuntu24.04)
REQUESTED_MACHINE=""
DISCOVERY_ERRORS=()
SELECTED_MACHINE_JSON=""
auto_select_cape_machine
[[ "$CAPE_MACHINE_SECTION" == "cuckoo1" ]]

collect_used_cidrs(){ printf '%s\n' '192.168.200.0/24' '192.168.122.0/24'; }
DISCOVERY_ERRORS=()
plan_isolated_subnet
[[ "$ISOLATED_SUBNET" != "192.168.200.0/24" ]]
[[ -n "$BRIDGE_IP" && -n "$INETSIM_IP" && -n "$WINDOWS_FAKE_IP" ]]

echo "[PASS] universal machine selection and subnet fallback"

# Reused management IPs must never cause "first domain wins" selection.
virsh() {
  if [[ "$1" == domifaddr ]]; then
    cat <<'EOF'
 Name       MAC address          Protocol     Address
-------------------------------------------------------------------------------
 vnet0      52:54:00:00:00:01    ipv4         192.0.2.44/24
EOF
    return 0
  fi
  return 1
}
LIBVIRT_DOMAINS=(domain-a domain-b)
ambiguous='{"section":"not-a-domain","label":"also-not-a-domain","ip":"192.0.2.44","snapshot":"s"}'
[[ -z "$(record_matches_domain "$ambiguous" 2>/dev/null || true)" ]]

TMP_CAPE="$(mktemp -d)"
mkdir -p "$TMP_CAPE/conf"
cat >"$TMP_CAPE/conf/kvm.conf" <<'EOF'
[win]
label = win
ip = 192.0.2.10
platform = windows
snapshot = s1

[linux]
label = linux
ip = 192.0.2.20
platform = linux
snapshot = s2
EOF
CAPE_ROOT="$TMP_CAPE"
DISCOVERY_ERRORS=()
discover_cape_machine_records
[[ "${#CAPE_MACHINE_RECORDS[@]}" -eq 1 ]]
[[ "$(record_field "${CAPE_MACHINE_RECORDS[0]}" section)" == win ]]
rm -rf "$TMP_CAPE"

# CAPE's [kvm] machines list is authoritative. Unlisted example/stale sections
# must not be treated as active analysis guests.
TMP_CAPE="$(mktemp -d)"
mkdir -p "$TMP_CAPE/conf"
cat >"$TMP_CAPE/conf/kvm.conf" <<'EOF'
[kvm]
machines = win10, win7

[cape1]
label = cape1
platform = windows
ip = 192.0.2.9

[win10]
label = win10
platform = windows
ip = 192.0.2.10

[win7]
label = win7
platform = windows
ip = 192.0.2.11

[linux1]
label = linux1
platform = linux
ip = 192.0.2.12
EOF
CAPE_ROOT="$TMP_CAPE"
DISCOVERY_ERRORS=()
discover_cape_machine_records
[[ "${#CAPE_MACHINE_RECORDS[@]}" -eq 2 ]]
[[ "$(record_field "${CAPE_MACHINE_RECORDS[0]}" section)" == win10 ]]
[[ "$(record_field "${CAPE_MACHINE_RECORDS[1]}" section)" == win7 ]]
rm -rf "$TMP_CAPE"

# An authoritative [kvm] list must never silently drop a broken or unsupported
# active entry.
TMP_CAPE="$(mktemp -d)"
mkdir -p "$TMP_CAPE/conf"
cat >"$TMP_CAPE/conf/kvm.conf" <<'EOF'
[kvm]
machines = win10, missing, linux1

[win10]
label = win10
platform = windows
ip = 192.0.2.10

[linux1]
label = linux1
platform = linux
ip = 192.0.2.12
EOF
CAPE_ROOT="$TMP_CAPE"
DISCOVERY_ERRORS=()
discover_cape_machine_records
[[ "${#CAPE_MACHINE_RECORDS[@]}" -eq 1 ]]
[[ "${#DISCOVERY_ERRORS[@]}" -eq 2 ]]
printf '%s\n' "${DISCOVERY_ERRORS[@]}" | grep -Fq 'missing section: missing'
printf '%s\n' "${DISCOVERY_ERRORS[@]}" | grep -Fq 'not Windows-compatible: linux1'
rm -rf "$TMP_CAPE"

TMP_DB="$(mktemp -d)"
mkdir -p "$TMP_DB/conf"
cat >"$TMP_DB/conf/cuckoo.conf" <<'EOF'
[database]
connection = postgresql+psycopg2://cape:do-not-print@db.internal/cape
EOF
CAPE_ROOT="$TMP_DB"
discover_cape_database_backend
[[ "$CAPE_DB_BACKEND" == postgresql ]]
cat >"$TMP_DB/conf/cuckoo.conf" <<'EOF'
[database]
connection =
EOF
discover_cape_database_backend
[[ "$CAPE_DB_BACKEND" == sqlite ]]
rm -rf "$TMP_DB"

grep -Fq 'automated live cutover currently requires CAPE PostgreSQL' "$ROOT/lib/deploy.sh"

grep -Fq 'COMPAT_STATUS:-blocked}" != "plan-compatible"' "$ROOT/lib/plan.sh"
grep -Fq 'CAPE LAYOUT NOT APPROVED FOR MUTATION -- SAFE STOP' "$ROOT/lib/plan.sh"

TMP_SNAP="$(mktemp -d)"
trap 'rm -rf "$TMP_SNAP"' EXIT
touch "$TMP_SNAP/windows.qcow2"
mkdir -p "$TMP_SNAP/bin"
cat >"$TMP_SNAP/bin/qemu-img" <<'EOF'
#!/usr/bin/env bash
printf '{"format":"qcow2"}\n'
EOF
chmod +x "$TMP_SNAP/bin/qemu-img"
OLD_PATH="$PATH"
PATH="$TMP_SNAP/bin:$PATH"
DOMAIN=testvm
DOMAIN_XML="<domain><devices><disk type='file' device='disk'><driver name='qemu' type='qcow2'/><source file='$TMP_SNAP/windows.qcow2'/></disk></devices></domain>"
DISCOVERY_ERRORS=()
discover_windows_snapshot_capability
[[ "$WINDOWS_INTERNAL_SNAPSHOT_CAPABLE" == yes ]]
[[ "${#DISCOVERY_ERRORS[@]}" -eq 0 ]]

DOMAIN_XML="<domain><devices><disk type='file' device='disk'><driver name='qemu' type='raw'/><source file='$TMP_SNAP/windows.qcow2'/></disk></devices></domain>"
DISCOVERY_ERRORS=()
discover_windows_snapshot_capability
[[ "$WINDOWS_INTERNAL_SNAPSHOT_CAPABLE" == no ]]
[[ "${#DISCOVERY_ERRORS[@]}" -eq 1 ]]
grep -Fq 'Windows disk driver is not declared qcow2' <<<"${DISCOVERY_ERRORS[0]}"

DOMAIN_XML="<domain><devices><disk type='file' device='disk' snapshot='no'><driver name='qemu' type='qcow2'/><source file='$TMP_SNAP/windows.qcow2'/></disk></devices></domain>"
DISCOVERY_ERRORS=()
discover_windows_snapshot_capability
[[ "$WINDOWS_INTERNAL_SNAPSHOT_CAPABLE" == no ]]
[[ "${#DISCOVERY_ERRORS[@]}" -eq 1 ]]
grep -Fq 'excluded from snapshots' <<<"${DISCOVERY_ERRORS[0]}"
PATH="$OLD_PATH"

grep -Fq 'targets_discover_all' "$ROOT/lib/plan.sh"
echo "[PASS] legacy snapshot-capability helper remains safe; route-scoped deploy does not require new snapshots"

# The configured CAPE snapshot itself must be running and may store saved
# memory internally or externally. It must carry the same proven management NIC.
DOMAIN=testvm
CAPE_MACHINE_SNAPSHOT=s1
MANAGEMENT_NETWORK_NAME=default
WINDOWS_MANAGEMENT_MAC=52:54:00:11:22:33
virsh() {
  if [[ "$1" == snapshot-dumpxml ]]; then
    cat <<'XML'
<domainsnapshot>
  <name>s1</name><state>running</state><memory snapshot='internal'/>
  <domain><name>testvm</name><devices>
    <interface type='network'><mac address='52:54:00:11:22:33'/><source network='default'/><model type='e1000e'/></interface>
  </devices></domain>
</domainsnapshot>
XML
    return 0
  fi
  return 1
}
DISCOVERY_ERRORS=()
discover_cape_analysis_snapshot
[[ "$CAPE_ANALYSIS_SNAPSHOT_STATUS" == proven ]]
[[ "$CAPE_ANALYSIS_SNAPSHOT_STATE" == running ]]
[[ "$CAPE_ANALYSIS_SNAPSHOT_MEMORY" == internal ]]
[[ "${#DISCOVERY_ERRORS[@]}" -eq 0 ]]

# Running external-memory snapshots are equally valid CAPE baselines.
virsh() {
  if [[ "$1" == snapshot-dumpxml ]]; then
    cat <<'XML'
<domainsnapshot>
  <name>s1</name><state>running</state><memory snapshot='external' file='/var/lib/libvirt/qemu/s1.mem'/>
  <domain><name>testvm</name><devices>
    <interface type='network'><mac address='52:54:00:11:22:33'/><source network='default'/><model type='e1000e'/></interface>
  </devices></domain>
</domainsnapshot>
XML
    return 0
  fi
  return 1
}
DISCOVERY_ERRORS=()
discover_cape_analysis_snapshot
[[ "$CAPE_ANALYSIS_SNAPSHOT_STATUS" == proven ]]
[[ "$CAPE_ANALYSIS_SNAPSHOT_STATE" == running ]]
[[ "$CAPE_ANALYSIS_SNAPSHOT_MEMORY" == external ]]
[[ "${#DISCOVERY_ERRORS[@]}" -eq 0 ]]

virsh() {
  if [[ "$1" == snapshot-dumpxml ]]; then
    cat <<'XML'
<domainsnapshot>
  <name>s1</name><state>shutoff</state><memory snapshot='no'/>
  <domain><name>testvm</name><devices>
    <interface type='network'><mac address='52:54:00:11:22:33'/><source network='default'/><model type='e1000e'/></interface>
  </devices></domain>
</domainsnapshot>
XML
    return 0
  fi
  return 1
}
DISCOVERY_ERRORS=()
discover_cape_analysis_snapshot
[[ "$CAPE_ANALYSIS_SNAPSHOT_STATUS" == unproven ]]
[[ "${#DISCOVERY_ERRORS[@]}" -eq 1 ]]
grep -Fq 'not a running-state analysis baseline with internal/external saved memory' <<<"${DISCOVERY_ERRORS[0]}"

CAPE_MACHINE_SNAPSHOT=""
DISCOVERY_ERRORS=()
discover_cape_analysis_snapshot
[[ "$CAPE_ANALYSIS_SNAPSHOT_STATUS" == not-configured ]]
[[ "${#DISCOVERY_ERRORS[@]}" -eq 0 ]]

grep -Fq 'discover_cape_analysis_snapshot' "$ROOT/lib/targets.sh"
grep -Fq 'analysis_snapshot_status") == "proven"' "$ROOT/lib/deploy.sh"
echo "[PASS] route-scoped deployment requires an existing proven CAPE analysis snapshot"

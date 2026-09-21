#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/cape.sh"
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
grep -Fq 'Windows disk is not qcow2' <<<"${DISCOVERY_ERRORS[0]}"
PATH="$OLD_PATH"

grep -Fq 'discover_windows_snapshot_capability' "$ROOT/lib/plan.sh"
grep -Fq 'internal snapshot capable:' "$ROOT/lib/plan.sh"
echo "[PASS] Windows internal-snapshot capability safe-stop preflight"

grep -Fq 'WINDOWS_INTERNAL_SNAPSHOT_CAPABLE:-no}" == yes' "$ROOT/lib/deploy.sh"

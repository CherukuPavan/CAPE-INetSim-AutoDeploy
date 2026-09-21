#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/libvirt.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/nwfilter"
touch "$TMP/windows.qcow2"
export QEMU_IMG_LOG="$TMP/qemu-img.log"

cat >"$TMP/bin/qemu-img" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >>"$QEMU_IMG_LOG"
printf '\n' >>"$QEMU_IMG_LOG"
case " $* " in
  *" --force-share "*)
    printf '{"format":"qcow2"}\n'
    exit 0
    ;;
esac
exit 1
EOF
chmod +x "$TMP/bin/qemu-img"
OLD_PATH="$PATH"
PATH="$TMP/bin:$PATH"

DOMAIN=testvm
DOMAIN_STATE=running
DOMAIN_XML="<domain><devices><disk type='file' device='disk'><driver name='qemu' type='qcow2'/><source file='$TMP/windows.qcow2'/></disk></devices></domain>"
DISCOVERY_ERRORS=()
discover_windows_snapshot_capability
[[ "$WINDOWS_INTERNAL_SNAPSHOT_CAPABLE" == yes ]]
[[ "${#DISCOVERY_ERRORS[@]}" -eq 0 ]]
grep -Fq -- '--force-share' "$QEMU_IMG_LOG"

# A non-qcow2 driver declaration must still safe-stop before trusting the file.
DOMAIN_XML="<domain><devices><disk type='file' device='disk'><driver name='qemu' type='raw'/><source file='$TMP/windows.qcow2'/></disk></devices></domain>"
DISCOVERY_ERRORS=()
discover_windows_snapshot_capability
[[ "$WINDOWS_INTERNAL_SNAPSHOT_CAPABLE" == no ]]
[[ "${#DISCOVERY_ERRORS[@]}" -eq 1 ]]
grep -Fq 'driver is not declared qcow2' <<<"${DISCOVERY_ERRORS[0]}"
PATH="$OLD_PATH"

cat >"$TMP/nwfilter/clean-traffic.xml" <<'EOF'
<filter name='clean-traffic' chain='root'/>
EOF
NWFILTER_DEFINITION_ROOT="$TMP/nwfilter"

virsh() {
  return 1
}
systemctl() {
  if [[ "$1" == show && "$2" == -p && "$3" == LoadState && "$4" == --value && "$5" == virtnwfilterd.socket ]]; then
    echo loaded
    return 0
  fi
  return 1
}
DISCOVERY_ERRORS=()
discover_hypervisor_safety_features
[[ "$MANAGEMENT_NWFILTER_AVAILABLE" == activatable ]]
[[ "$NWFILTER_RUNTIME_MODE" == modular-socket ]]
[[ "${#DISCOVERY_ERRORS[@]}" -eq 0 ]]

rm -f "$TMP/nwfilter/clean-traffic.xml"
DISCOVERY_ERRORS=()
discover_hypervisor_safety_features
[[ "$MANAGEMENT_NWFILTER_AVAILABLE" == no ]]
[[ "$NWFILTER_RUNTIME_MODE" == unavailable ]]
[[ "${#DISCOVERY_ERRORS[@]}" -eq 1 ]]
grep -Fq 'no activatable standard virtnwfilterd configuration was proven' <<<"${DISCOVERY_ERRORS[0]}"

virsh() {
  [[ "$1" == nwfilter-info && "$2" == clean-traffic ]]
}
DISCOVERY_ERRORS=()
discover_hypervisor_safety_features
[[ "$MANAGEMENT_NWFILTER_AVAILABLE" == yes ]]
[[ "$NWFILTER_RUNTIME_MODE" == ready ]]
[[ "${#DISCOVERY_ERRORS[@]}" -eq 0 ]]

echo '[PASS] live qcow2 and modular nwfilter discovery are safe and machine-agnostic'

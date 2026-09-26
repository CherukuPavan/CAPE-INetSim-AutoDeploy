#!/usr/bin/env bash

# ============================================================
# CAPE INetSim VM Extension
# Read-only pre-installation verifier
# ============================================================
#
# This script performs validation only.
# It does NOT modify CAPE, libvirt, networking, or system files.
#

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="${1:-$EXT_ROOT/src/inetsim-vm.conf}"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0


pass() {
    printf '  [PASS] %s\n' "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}


warn() {
    printf '  [WARN] %s\n' "$1"
    WARN_COUNT=$((WARN_COUNT + 1))
}


fail() {
    printf '  [FAIL] %s\n' "$1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}


info() {
    printf '  [INFO] %s\n' "$1"
}


valid_ipv4() {
    python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress
import sys

try:
    ipaddress.IPv4Address(sys.argv[1])
except Exception:
    raise SystemExit(1)
PY
}


section_value() {
    local file="$1"
    local section="$2"
    local key="$3"

    awk \
        -v section="[$section]" \
        -v key="$key" '
        $0 == section {
            inside = 1
            next
        }

        /^\[/ {
            if (inside)
                exit
        }

        inside && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            line = $0
            sub(/^[^=]*=[[:space:]]*/, "", line)
            sub(/[[:space:]]*$/, "", line)
            print line
            exit
        }
    ' "$file"
}


echo
echo "============================================================"
echo " CAPE INETSIM VM EXTENSION - PRE-INSTALLATION VERIFICATION"
echo "============================================================"
echo
echo "Mode: READ ONLY"
echo "No CAPE, network, VM, or operating-system files will be changed."
echo


# ------------------------------------------------------------
# 1. Configuration file
# ------------------------------------------------------------

echo "1. Extension configuration"

if [[ -r "$CONFIG_FILE" ]]; then
    pass "Configuration file found: $CONFIG_FILE"
else
    fail "Configuration file not found: $CONFIG_FILE"

    echo
    echo "Verification cannot continue without the configuration file."
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# CAPE section names and libvirt domain names are allowed to differ.
# Older extension configurations did not carry CAPE_DOMAIN, so retain a
# backwards-compatible fallback for standalone use.
CAPE_DOMAIN="${CAPE_DOMAIN:-${CAPE_MACHINE:-}}"
CAPE_MACHINE_LABEL="${CAPE_MACHINE_LABEL:-${CAPE_MACHINE:-}}"
AUTODEPLOY_MANAGED="${AUTODEPLOY_MANAGED:-0}"

managed_warn_or_fail() {
    if [[ "$AUTODEPLOY_MANAGED" == "1" ]]; then
        warn "$1"
    else
        fail "$1"
    fi
}


# ------------------------------------------------------------
# 2. Required configuration variables
# ------------------------------------------------------------

echo
echo "2. Required configuration values"

REQUIRED_VARS=(
    CAPE_ROOT
    CAPE_MACHINE
    CAPE_GUEST_CONTROL_IP
    CAPE_RESULTSERVER_IP
    INETSIM_SERVER_IP
    ANALYSIS_GUEST_IP
    CAPTURE_INTERFACE
)

for var in "${REQUIRED_VARS[@]}"; do
    value="${!var:-}"

    if [[ -n "$value" ]]; then
        pass "$var = $value"
    else
        fail "$var is missing or empty"
    fi
done


# ------------------------------------------------------------
# 3. IPv4 validation
# ------------------------------------------------------------

echo
echo "3. IPv4 address validation"

IP_VARS=(
    CAPE_GUEST_CONTROL_IP
    CAPE_RESULTSERVER_IP
    INETSIM_SERVER_IP
    ANALYSIS_GUEST_IP
)

if command -v python3 >/dev/null 2>&1; then

    for var in "${IP_VARS[@]}"; do
        value="${!var:-}"

        if [[ -n "$value" ]] && valid_ipv4 "$value"; then
            pass "$var is a valid IPv4 address: $value"
        else
            fail "$var is not a valid IPv4 address: ${value:-<empty>}"
        fi
    done

else
    fail "python3 is unavailable; IPv4 validation cannot run"
fi


# ------------------------------------------------------------
# 4. CAPE installation
# ------------------------------------------------------------

echo
echo "4. CAPEv2 installation"

if [[ -d "${CAPE_ROOT:-}" ]]; then
    pass "CAPE directory exists: $CAPE_ROOT"
else
    fail "CAPE directory does not exist: ${CAPE_ROOT:-<empty>}"
fi


BASELINE_FILES=(
    "web/analysis/views.py"
    "web/analysis/templatetags/__init__.py"
    "web/analysis/templatetags/analysis_tags.py"
    "web/templates/analysis/network/index.html"
)

for relative in "${BASELINE_FILES[@]}"; do

    file="${CAPE_ROOT:-}/$relative"

    if [[ -f "$file" ]]; then
        pass "Required CAPE file exists: $relative"
    else
        fail "Required CAPE file is missing: $relative"
    fi

done


# ------------------------------------------------------------
# 5. Existing INetSim components are optional on modern CAPE
# ------------------------------------------------------------

echo
echo "5. Optional existing INetSim processing component"

CUSTOM_FILES=(
    "modules/processing/inetsim.py"
)

for relative in "${CUSTOM_FILES[@]}"; do

    file="${CAPE_ROOT:-}/$relative"

    if [[ -f "$file" ]]; then
        info "Existing custom component detected: $relative"
    else
        info "Component not currently installed: $relative"
    fi

done


# ------------------------------------------------------------
# 6. Capture interface
# ------------------------------------------------------------

echo
echo "6. Host capture interface"

if command -v ip >/dev/null 2>&1; then

    if ip link show "${CAPTURE_INTERFACE:-}" >/dev/null 2>&1; then
        pass "Capture interface exists: $CAPTURE_INTERFACE"

        state="$(
            ip -br link show "$CAPTURE_INTERFACE" 2>/dev/null |
            awk '{print $2}'
        )"

        info "Current interface state: ${state:-unknown}"

    else
        managed_warn_or_fail "Capture interface does not exist: ${CAPTURE_INTERFACE:-<empty>}"
    fi

else
    managed_warn_or_fail "'ip' command is unavailable"
fi


# ------------------------------------------------------------
# 7. Route to INetSim
# ------------------------------------------------------------

echo
echo "7. Host route to INetSim server"

if command -v ip >/dev/null 2>&1; then

    route_output="$(
        ip route get "${INETSIM_SERVER_IP:-}" 2>/dev/null |
        head -1
    )"

    if [[ -n "$route_output" ]]; then

        info "$route_output"

        if grep -Eq "(^|[[:space:]])dev[[:space:]]+${CAPTURE_INTERFACE}([[:space:]]|$)" \
            <<< "$route_output"; then

            pass "INetSim server is routed through $CAPTURE_INTERFACE"

        else

            warn "Route to $INETSIM_SERVER_IP does not appear to use $CAPTURE_INTERFACE"

        fi

    else
        warn "No route could be resolved for $INETSIM_SERVER_IP"
    fi

fi


# ------------------------------------------------------------
# 8. Libvirt / analysis VM
# ------------------------------------------------------------

echo
echo "8. Analysis virtual machine"

if command -v virsh >/dev/null 2>&1; then

    if virsh dominfo "${CAPE_DOMAIN:-}" >/dev/null 2>&1; then

        pass "libvirt domain exists: $CAPE_DOMAIN"

        vm_state="$(
            virsh domstate "$CAPE_DOMAIN" 2>/dev/null |
            head -1 |
            xargs
        )"

        info "Current VM state: ${vm_state:-unknown}"

    else

        warn "Could not query libvirt domain '$CAPE_DOMAIN' as the current user"
        info "If the VM exists, check libvirt permissions or run: sudo virsh dominfo $CAPE_DOMAIN"

    fi

else
    managed_warn_or_fail "'virsh' command is unavailable"
fi


# ------------------------------------------------------------
# 9. CAPE KVM machine configuration
# ------------------------------------------------------------

echo
echo "9. CAPE machine configuration"

KVM_CONF="${CAPE_ROOT:-}/conf/kvm.conf"

if [[ -r "$KVM_CONF" ]] &&
   grep -Fxq "[$CAPE_MACHINE]" "$KVM_CONF"; then

    pass "[$CAPE_MACHINE] section exists in conf/kvm.conf"

    configured_ip="$(
        section_value "$KVM_CONF" "$CAPE_MACHINE" "ip"
    )"

    configured_resultserver="$(
        section_value "$KVM_CONF" "$CAPE_MACHINE" "resultserver_ip"
    )"

    configured_interface="$(
        section_value "$KVM_CONF" "$CAPE_MACHINE" "interface"
    )"

    configured_snapshot="$(
        section_value "$KVM_CONF" "$CAPE_MACHINE" "snapshot"
    )"

    info "Configured machine IP: ${configured_ip:-<not set>}"
    info "Configured ResultServer IP: ${configured_resultserver:-<not set>}"
    info "Configured capture interface: ${configured_interface:-<not set>}"
    info "Configured snapshot: ${configured_snapshot:-<not set>}"

    if [[ "$configured_ip" == "$CAPE_GUEST_CONTROL_IP" ]]; then
        pass "CAPE machine control IP matches extension configuration"
    else
        warn "CAPE machine IP differs from CAPE_GUEST_CONTROL_IP"
    fi

    if [[ "$configured_resultserver" == "$CAPE_RESULTSERVER_IP" ]]; then
        pass "ResultServer IP matches extension configuration"
    else
        warn "Configured ResultServer IP differs from extension configuration"
    fi

    if [[ "$AUTODEPLOY_MANAGED" == "1" ]]; then
        AUX_CONF="${CAPE_ROOT:-}/conf/auxiliary.conf"
        route_capture_interface=""
        route_capture_host=""
        if [[ -r "$AUX_CONF" ]]; then
            route_capture_interface="$(section_value "$AUX_CONF" "sniffer" "inetsim_capture_interface_${CAPE_MACHINE_LABEL}")"
            route_capture_host="$(section_value "$AUX_CONF" "sniffer" "inetsim_capture_host_${CAPE_MACHINE_LABEL}")"
        fi

        info "Normal-route CAPE capture interface: ${configured_interface:-<not set>}"
        info "route=inetsim capture interface: ${route_capture_interface:-<not set>}"

        if [[ "$route_capture_interface" == "$CAPTURE_INTERFACE" ]]; then
            pass "route=inetsim capture override matches isolated interface $CAPTURE_INTERFACE"
        else
            fail "route=inetsim capture override does not match isolated interface"
        fi

        if [[ "$route_capture_host" == "$CAPE_GUEST_CONTROL_IP" ]]; then
            pass "route=inetsim capture host matches CAPE guest control IP"
        else
            fail "route=inetsim capture host does not match CAPE guest control IP"
        fi

        if [[ -n "$configured_interface" && "$configured_interface" != "$CAPTURE_INTERFACE" ]]; then
            pass "Normal-route management capture remains separate from isolated INetSim capture"
        else
            fail "Normal-route and isolated INetSim capture interfaces are not safely separated"
        fi
    elif [[ "$configured_interface" == "$CAPTURE_INTERFACE" ]]; then
        pass "Capture interface matches extension configuration"
    else
        warn "Configured capture interface differs from extension configuration"
    fi

else

    managed_warn_or_fail "[$CAPE_MACHINE] section was not found in conf/kvm.conf"

fi


# ------------------------------------------------------------
# 10. Important system commands
# ------------------------------------------------------------

echo
echo "10. Required system commands"

COMMANDS=(
    python3
    ip
    virsh
    grep
    awk
    sed
    sha256sum
    mktemp
)

for cmd in "${COMMANDS[@]}"; do

    if command -v "$cmd" >/dev/null 2>&1; then
        pass "Command available: $cmd"
    else
        fail "Required command missing: $cmd"
    fi

done


# ------------------------------------------------------------
# Final result
# ------------------------------------------------------------

echo
echo "============================================================"
echo " VERIFICATION SUMMARY"
echo "============================================================"

printf 'PASS: %d\n' "$PASS_COUNT"
printf 'WARN: %d\n' "$WARN_COUNT"
printf 'FAIL: %d\n' "$FAIL_COUNT"

echo

if (( FAIL_COUNT == 0 )); then

    echo "STATUS: PRE-INSTALLATION VERIFICATION PASSED"

    if (( WARN_COUNT > 0 )); then
        echo "Some warnings were reported above."
        echo "Review them before installation."
    else
        echo "No blocking problems were detected."
    fi

    echo
    echo "READ-ONLY CHECK COMPLETE."
    echo "No production CAPE files were modified."

    exit 0

else

    echo "STATUS: PRE-INSTALLATION VERIFICATION FAILED"
    echo
    echo "Do NOT install the extension yet."
    echo "Correct the FAIL items shown above and run verify.sh again."
    echo
    echo "No production CAPE files were modified."

    exit 1

fi

#!/usr/bin/env bash

run_discovery() {
  DISCOVERY_ERRORS=(); COMPAT_NOTES=(); REQUESTED_MACHINE="${REQUESTED_MACHINE:-}"
  discover_cape_root
  discover_cape_git
  discover_cape_services
  discover_cape_machine_records
  discover_libvirt
  auto_select_cape_machine
  match_selected_domain
  discover_domain_details
  discover_windows_backends
  plan_isolated_subnet
  discover_busy_state
  check_cape_layout
  discover_resources
}

print_plan() {
  echo
  echo "============================================================"
  echo " ${AD_NAME} ${AD_VERSION} -- READ-ONLY PLAN"
  echo "============================================================"
  echo
  [[ -n "${CAPE_ROOT:-}" ]] && pass "CAPE installation discovered" || fail "CAPE installation not uniquely discovered"
  [[ -n "${LIBVIRT_URI:-}" ]] && pass "KVM/libvirt discovered" || fail "KVM/libvirt unavailable"
  [[ -n "${CAPE_MACHINE_SECTION:-}" ]] && pass "CAPE analysis machine auto-selected" || fail "CAPE analysis machine not uniquely selected"
  [[ -n "${DOMAIN:-}" ]] && pass "Matching libvirt domain discovered" || fail "Matching libvirt domain not discovered"
  [[ -n "${ISOLATED_SUBNET:-}" ]] && pass "Unused isolated-network candidate selected" || fail "No isolated-network candidate selected"

  echo; echo "Discovery"
  kv "CAPE root:" "${CAPE_ROOT:-NOT FOUND}"
  kv "CAPE commit:" "${CAPE_COMMIT:-unknown}"
  kv "CAPE branch:" "${CAPE_BRANCH:-unknown}"
  kv "CAPE working tree dirty:" "${CAPE_DIRTY:-unknown}"
  kv "libvirt URI:" "${LIBVIRT_URI:-unknown}"
  kv "CAPE machine section:" "${CAPE_MACHINE_SECTION:-ambiguous}"
  kv "CAPE machine label:" "${CAPE_MACHINE_LABEL:-ambiguous}"
  kv "management IP:" "${CAPE_MACHINE_IP:-unknown}"
  kv "current CAPE snapshot:" "${CAPE_MACHINE_SNAPSHOT:-unknown}"
  kv "current CAPE interface:" "${CAPE_MACHINE_INTERFACE:-unknown}"
  kv "libvirt domain:" "${DOMAIN:-ambiguous}"
  kv "domain state:" "${DOMAIN_STATE:-unknown}"
  kv "NIC count:" "${DOMAIN_NIC_COUNT:-unknown}"
  kv "NIC model(s):" "${DOMAIN_NIC_MODELS:-unknown}"

  echo; echo "Windows control"
  kv "QEMU Guest Agent:" "${QGA_AVAILABLE:-unknown}"
  kv "WinRM reachable:" "${WINRM_AVAILABLE:-unknown}"
  kv "CAPE agent :8000 reachable:" "${CAPE_AGENT_REACHABLE:-unknown}"
  kv "selected/fallback backend:" "${WINDOWS_BACKEND:-unknown}"

  echo; echo "Network plan"
  kv "isolated subnet:" "${ISOLATED_SUBNET:-unavailable}"
  kv "bridge address:" "${BRIDGE_IP:-unavailable}"
  kv "INetSim address:" "${INETSIM_IP:-unavailable}"
  kv "Windows fake-Internet IP:" "${WINDOWS_FAKE_IP:-unavailable}"
  kv "Windows DNS:" "${INETSIM_IP:-unavailable}"
  kv "CAPE capture address:" "${WINDOWS_FAKE_IP:-unavailable}"

  echo; echo "Safety / compatibility"
  kv "CAPE busy signal:" "${CAPE_BUSY:-unknown}"
  kv "busy reason:" "${BUSY_REASON:-unknown}"
  kv "compatibility state:" "${COMPAT_STATUS:-unknown}"
  kv "compatibility notes:" "$(IFS=,; echo "${COMPAT_NOTES[*]:-none}")"
  kv "host RAM KiB:" "${HOST_MEM_KIB:-unknown}"
  kv "libvirt image free KiB:" "${LIBVIRT_FREE_KIB:-unknown}"

  echo; echo "Future deployment will create/configure"
  echo "  - generalized Ubuntu INetSim appliance"
  echo "  - isolated libvirt network with no NAT/default gateway"
  echo "  - secondary NIC on the selected Windows analysis VM"
  echo "  - Windows fake-Internet IP/DNS while preserving CAPE management"
  echo "  - CAPE-compatible running-state analysis snapshot"
  echo "  - per-machine CAPE capture on the isolated network"
  echo "  - Network Analysis visibility for simulated traffic"
  echo "  - CAPE-INetSim-VM-Extension integration"

  echo
  if ((${#DISCOVERY_ERRORS[@]})); then
    echo "Blocking/ambiguous findings"; printf '  - %s\n' "${DISCOVERY_ERRORS[@]}"; echo
    echo "RESULT: PLAN INCOMPLETE -- SAFE STOP"
  elif [[ "${COMPAT_STATUS:-blocked}" == "blocked" ]]; then
    echo "RESULT: UNSUPPORTED ENVIRONMENT -- SAFE STOP"
  else
    echo "RESULT: DEPLOYMENT PLAN DISCOVERED"
    [[ "${CAPE_BUSY:-unknown}" == "yes" ]] && echo "CUTOVER: must wait for a task-aware safe idle point"
  fi
  echo "NO SYSTEM CONFIGURATION WAS CHANGED"
  echo "============================================================"
}

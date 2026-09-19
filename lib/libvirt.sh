#!/usr/bin/env bash

discover_libvirt() {
  LIBVIRT_URI=""; LIBVIRT_DOMAINS=(); LIBVIRT_NETWORKS=()
  if ! have virsh; then add_error "virsh is not installed"; return 0; fi
  LIBVIRT_URI="$(virsh uri 2>/dev/null || true)"
  [[ -n "$LIBVIRT_URI" ]] || add_error "libvirt connection is unavailable"
  mapfile -t LIBVIRT_DOMAINS < <(virsh list --all --name 2>/dev/null | sed '/^$/d')
  mapfile -t LIBVIRT_NETWORKS < <(virsh net-list --all --name 2>/dev/null | sed '/^$/d')
  ((${#LIBVIRT_DOMAINS[@]} > 0)) || add_error "No libvirt domains were found"
}

record_matches_domain() {
  local rec="$1" d section label ip
  section="$(record_field "$rec" section)"; label="$(record_field "$rec" label)"; ip="$(record_field "$rec" ip)"
  for d in "${LIBVIRT_DOMAINS[@]}"; do
    if [[ "$d" == "$section" || "$d" == "$label" ]]; then printf '%s\n' "$d"; return 0; fi
  done
  if [[ -n "$ip" ]]; then
    for d in "${LIBVIRT_DOMAINS[@]}"; do
      if virsh domifaddr "$d" --source agent 2>/dev/null | grep -Fq "$ip" || virsh domifaddr "$d" --source lease 2>/dev/null | grep -Fq "$ip"; then printf '%s\n' "$d"; return 0; fi
    done
  fi
  return 1
}

auto_select_cape_machine() {
  [[ -n "${REQUESTED_MACHINE:-}" ]] && { select_machine_by_request "$REQUESTED_MACHINE"; set_selected_machine_fields; return 0; }
  local rec d
  local -a matched_records=()
  for rec in "${CAPE_MACHINE_RECORDS[@]}"; do
    d="$(record_matches_domain "$rec" 2>/dev/null || true)"
    [[ -n "$d" ]] && matched_records+=("$rec")
  done
  if ((${#matched_records[@]} == 1)); then
    SELECTED_MACHINE_JSON="${matched_records[0]}"
  elif ((${#CAPE_MACHINE_RECORDS[@]} == 1)); then
    SELECTED_MACHINE_JSON="${CAPE_MACHINE_RECORDS[0]}"
  else
    local choices=()
    for rec in "${CAPE_MACHINE_RECORDS[@]}"; do choices+=("$(record_field "$rec" section)"); done
    add_error "Could not uniquely auto-select a CAPE analysis machine; candidates: ${choices[*]}"
  fi
  set_selected_machine_fields
}

match_selected_domain() {
  DOMAIN=""
  [[ -n "${SELECTED_MACHINE_JSON:-}" ]] || return 0
  DOMAIN="$(record_matches_domain "$SELECTED_MACHINE_JSON" 2>/dev/null || true)"
  [[ -n "$DOMAIN" ]] || add_error "Could not map selected CAPE machine to a libvirt domain"
}

discover_domain_details() {
  DOMAIN_STATE="unknown"; DOMAIN_NIC_COUNT="unknown"; DOMAIN_NIC_MODELS="unknown"; DOMAIN_XML=""
  [[ -n "${DOMAIN:-}" ]] || return 0
  DOMAIN_STATE="$(virsh domstate "$DOMAIN" 2>/dev/null | head -1 | xargs || true)"
  DOMAIN_XML="$(virsh dumpxml "$DOMAIN" 2>/dev/null || true)"
  DOMAIN_NIC_COUNT="$(grep -c '<interface type=' <<<"$DOMAIN_XML" || true)"
  DOMAIN_NIC_MODELS="$(grep -oE "<model type='[^']+'" <<<"$DOMAIN_XML" | sed "s/.*type='//;s/'$//" | sort -u | paste -sd, -)"
}

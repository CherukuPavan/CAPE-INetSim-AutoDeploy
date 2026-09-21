#!/usr/bin/env bash

validate_windows_result_path() {
  local f="$1"
  [[ -f "$f" ]] || { fail "Windows verification record missing: $f"; return 1; }
  python3 - "$f" "${WINDOWS_FAKE_IP:-}" "${INETSIM_IP:-}" <<'PY'
import json,sys
path,expected_fake,expected_dns=sys.argv[1:]
with open(path,encoding="utf-8-sig") as h:
    d=json.load(h)
def req(cond,msg):
    if not cond:
        raise SystemExit(msg)
req(d.get("ok") is True,"Windows result is not ok")
req(int(d.get("default_routes",-1)) == 0,"default route count is not zero")
req(int(d.get("ipv4_default_routes",-1)) == 0,"IPv4 default route count is not zero")
req(int(d.get("ipv6_default_routes",-1)) == 0,"IPv6 default route count is not zero")
req(int(d.get("ipv6_bindings_enabled",-1)) == 0,"IPv6 bindings remain enabled")
req(int(d.get("unexpected_active_adapters",-1)) == 0,"unexpected active adapter remains")
req(d.get("resultserver_reachable") is True,"ResultServer is not reachable")
req(d.get("inetsim_http_reachable") is True,"INetSim HTTP is not reachable")
req(d.get("inetsim_https_reachable") is True,"INetSim HTTPS is not reachable")
req(d.get("public_ip_reachable") is False,"public IPv4 is reachable")
req(d.get("public_ipv6_reachable") is False,"public IPv6 is reachable")
if expected_fake:
    got=d.get("fake_ip",d.get("isolated_ip",""))
    req(got == expected_fake,f"fake IP mismatch: {got!r}")
if expected_dns:
    req(d.get("dns","") == expected_dns,f"DNS mismatch: {d.get('dns')!r}")
PY
}

validate_windows_result_file() {
  validate_windows_result_path "$AD_LOG_ROOT/${DEPLOYMENT_ID}-windows-verify.json"
}

validate_final_snapshot_hardware() {
  local xml
  xml="$(virsh snapshot-dumpxml "$DOMAIN" "$FINAL_SNAPSHOT")" || return 1
  python3 -c '
import sys,xml.etree.ElementTree as ET
net,mac=sys.argv[1],sys.argv[2].lower()
r=ET.fromstring(sys.stdin.read())
if (r.findtext("state") or "")!="running": raise SystemExit("snapshot state is not running")
mem=r.find("memory")
if mem is None or mem.get("snapshot")!="internal": raise SystemExit("snapshot has no internal memory state")
dom=r.find("domain")
if dom is None: raise SystemExit("snapshot has no embedded domain XML")
found=False
for i in dom.findall("./devices/interface"):
    s=i.find("source"); m=i.find("mac")
    if s is not None and s.get("network")==net and m is not None and (m.get("address") or "").lower()==mac:
        found=True
if not found: raise SystemExit("snapshot does not contain the isolated NIC")
' "$ISOLATED_NETWORK_NAME" "$WINDOWS_ISOLATED_MAC" <<<"$xml"
}

validate_cape_configuration() {
  python3 - "$CAPE_ROOT" "$CAPE_MACHINE_SECTION" "$CAPE_MACHINE_LABEL" "$FINAL_SNAPSHOT" "$ISOLATED_BRIDGE_NAME" "$WINDOWS_FAKE_IP" <<'PY'
import configparser,sys
root,section,label,snapshot,iface,fake=sys.argv[1:]
def load(name):
    c=configparser.ConfigParser(interpolation=None,strict=False)
    c.optionxform=str.lower
    c.read(f"{root}/conf/{name}.conf")
    return c
k=load("kvm")
a=load("auxiliary")
p=load("processing")
r=load("routing")
if not k.has_section(section): raise SystemExit("CAPE machine section missing")
if k.get(section,"snapshot",fallback="") != snapshot: raise SystemExit("CAPE snapshot mismatch")
if k.get(section,"interface",fallback="") != iface: raise SystemExit("CAPE interface mismatch")
if a.get("sniffer",f"capture_host_{label}",fallback="") != fake: raise SystemExit("capture host mismatch")
if p.get("network","dnswhitelist",fallback="").lower() != "no": raise SystemExit("dnswhitelist not disabled")
if p.get("network","ipwhitelist",fallback="").lower() != "no": raise SystemExit("ipwhitelist not disabled")
if r.get("routing","route",fallback="").lower() != "none": raise SystemExit("CAPE default route is not none")
if r.get("routing","enable_pcap",fallback="").lower() not in ("yes","true","1","on"): raise SystemExit("CAPE packet capture is disabled for route none")
PY
  grep -q 'CAPE_INETSIM_AUTODEPLOY_CAPTURE_V1' "$CAPE_ROOT/modules/auxiliary/sniffer.py"
}

validate_resultserver_host() {
  [[ "${CAPE_SERVICE_WAS_ACTIVE:-yes}" == yes ]] || return 0
  timeout 3 bash -c "</dev/tcp/$CAPE_RESULTSERVER_IP/$CAPE_RESULTSERVER_PORT" >/dev/null 2>&1 || {
    fail "CAPE ResultServer is not reachable at $CAPE_RESULTSERVER_IP:$CAPE_RESULTSERVER_PORT"
    return 1
  }
}

validate_deployment_structural() {
  verify_isolated_network_definition "$ISOLATED_NETWORK_NAME" "$ISOLATED_BRIDGE_NAME" "$ISOLATED_SUBNET" "$BRIDGE_IP"
  firewall_verify
  windows_management_guard_verify
  inetsim_verify_host
  validate_windows_result_file
  validate_final_snapshot_hardware
  validate_cape_configuration
  grep -Rqs 'CAPE_INETSIM_VM_ROUTE_NONE_V1' "$CAPE_ROOT/web"
  pass "Structural deployment gates passed"
}

validate_deployment_services() {
  services_validate_restored_state
  validate_resultserver_host
  pass "CAPE service and ResultServer health gates passed"
}

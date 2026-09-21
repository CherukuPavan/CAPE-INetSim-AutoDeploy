#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${1:-}"
[[ -n "$IMAGE" && -f "$IMAGE" ]] || { echo "[FAIL] usage: $0 IMAGE.qcow2" >&2; exit 2; }

need(){ command -v "$1" >/dev/null 2>&1 || { echo "[FAIL] missing verifier command: $1" >&2; exit 2; }; }
for x in qemu-img virt-cat virt-ls python3 grep; do need "$x"; done

info_json="$(qemu-img info --output=json "$IMAGE")"
python3 - "$info_json" <<'PY'
import json,sys
d=json.loads(sys.argv[1])
if d.get("format")!="qcow2":
    raise SystemExit("candidate is not qcow2")
for k in ("backing-filename","full-backing-filename","data-file","full-data-filename"):
    if d.get(k):
        raise SystemExit(f"candidate has forbidden external dependency: {k}")
if int(d.get("virtual-size",0)) < 20_000_000_000:
    raise SystemExit("candidate virtual size is below 20 GiB policy")
PY
qemu-img check "$IMAGE" >/dev/null

os_release="$(virt-cat -a "$IMAGE" /etc/os-release)"
grep -Fxq 'VERSION_ID="24.04"' <<<"$os_release"

lowports="$(virt-cat -a "$IMAGE" /etc/sysctl.d/99-inetsim-lowports.conf | tr -d '\r')"
[[ "$lowports" == 'net.ipv4.ip_unprivileged_port_start=53' ]]

isolation="$(virt-cat -a "$IMAGE" /etc/sysctl.d/99-cape-inetsim-isolation.conf | tr -d '\r')"
grep -Fxq 'net.ipv4.ip_forward=0' <<<"$isolation"
grep -Fxq 'net.ipv6.conf.all.forwarding=0' <<<"$isolation"

guest_config="$(virt-cat -a "$IMAGE" /usr/local/sbin/cape-inetsim-guest-configure)"
grep -Fq -- '--management-mac' <<<"$guest_config"
grep -Fq -- '--isolated-mac' <<<"$guest_config"
grep -Fq 'service_bind_address' <<<"$guest_config"
grep -Fq 'dns_default_ip' <<<"$guest_config"
! grep -Eq '192\.168\.200\.|192\.168\.122\.' <<<"$guest_config"

dns_pm="$(virt-cat -a "$IMAGE" /usr/share/perl5/INetSim/DNS.pm)"
grep -Fq 'loop_once(10)' <<<"$dns_pm"

virt-cat -a "$IMAGE" /etc/cloud/cloud-init.disabled >/dev/null

machine_id="$(virt-cat -a "$IMAGE" /etc/machine-id 2>/dev/null | tr -d '[:space:]' || true)"
python3 - "$machine_id" <<'PY'
import re,sys
v=sys.argv[1].lower()
if re.fullmatch(r"[0-9a-f]{32}",v) and v != "0"*32:
    raise SystemExit("candidate contains a persistent machine-id")
PY

ssh_listing="$(virt-ls -a "$IMAGE" /etc/ssh 2>/dev/null || true)"
if grep -Eq '^ssh_host_.*_key$' <<<"$ssh_listing"; then
  echo "[FAIL] candidate contains persistent SSH host private keys" >&2
  exit 3
fi

dpkg_status="$(virt-cat -a "$IMAGE" /var/lib/dpkg/status)"
# Keep the package checks in shell so package names are visible in logs.
grep -Eq '^Package: inetsim$' <<<"$dpkg_status"
grep -Eq '^Package: qemu-guest-agent$' <<<"$dpkg_status"

cloud_instances="$(virt-ls -R -a "$IMAGE" /var/lib/cloud/instances 2>/dev/null || true)"
[[ -z "${cloud_instances//[[:space:]]/}" ]] || {
  echo "[FAIL] candidate still contains cloud-init instance state" >&2
  exit 4
}

echo "[PASS] generalized INetSim appliance artifact verification"

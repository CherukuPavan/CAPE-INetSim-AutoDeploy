#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/targets.sh"
AD_STATE_ROOT=/tmp/unused
APPLIANCE_CACHE_ROOT=/tmp/unused-cache
source "$ROOT/lib/extension.sh"

[[ "$EXTENSION_VERSION" == 1.0.2 ]]
[[ "$EXTENSION_BUNDLED_ROOT" == "$ROOT/vendor/CAPE-INetSim-VM-Extension-v1.0.2" ]]
(cd "$EXTENSION_BUNDLED_ROOT" && sha256sum -c RUNTIME-SHA256SUMS >/dev/null)
grep -Fq 'Bundled INetSim extension runtime' "$ROOT/lib/extension.sh"
! grep -Fq 'CAPE-INetSim-VM-Extension/releases/download' "$ROOT/lib/extension.sh"
! grep -Fq 'EXTENSION_RELEASE_ASSET_SHA256' "$ROOT/lib/extension.sh"
grep -Fq 'AUTODEPLOY_MANAGED=1' "$ROOT/lib/extension.sh"
grep -Fq 'refreshing-unowned-runtime' "$ROOT/lib/extension.sh"
grep -Fq 'extension_run_logged init-config' "$ROOT/lib/extension.sh"
grep -Fq 'extension_run_logged verify' "$ROOT/lib/extension.sh"
grep -Fq 'managed_warn_or_fail' "$EXTENSION_BUNDLED_ROOT/scripts/verify.sh"
grep -Fq 'web/analysis/templatetags/analysis_tags.py' "$EXTENSION_BUNDLED_ROOT/scripts/verify.sh"
grep -Fq 'web/templates/analysis/network/index.html' "$EXTENSION_BUNDLED_ROOT/scripts/verify.sh"
grep -Fq 'web/analysis/templatetags/__init__.py' "$EXTENSION_BUNDLED_ROOT/scripts/verify.sh"
! grep -Fq '"web/analysis/templatetags/inetsim_tags.py"' "$EXTENSION_BUNDLED_ROOT/scripts/verify.sh"
! grep -Fq '"web/templates/analysis/network/_inetsim_visual.html"' "$EXTENSION_BUNDLED_ROOT/scripts/verify.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Config writer remains machine/domain-name safe.
EXTENSION_ROOT="$TMP/config-ext"
mkdir -p "$EXTENSION_ROOT/src"
CAPE_ROOT='/opt/CAPE test/$root'
INETSIM_IP='198.51.100.2'
ISOLATED_BRIDGE_NAME='capeisim7'
CAPE_TARGETS_JSON='[{"section":"win test","label":"win-label","ip":"192.0.2.100","domain":"actual-domain","resultserver_ip":"192.0.2.1","resultserver_port":"2042","control_host_ip":"192.0.2.1","fake_ip":"198.51.100.10"}]'
CAPE_TARGETS_COUNT=1
TARGET_INDEX=""
extension_write_config
unset CAPE_ROOT CAPE_MACHINE CAPE_DOMAIN CAPE_GUEST_CONTROL_IP CAPE_RESULTSERVER_IP INETSIM_SERVER_IP ANALYSIS_GUEST_IP CAPTURE_INTERFACE
# shellcheck disable=SC1090
source "$EXTENSION_ROOT/src/inetsim-vm.conf"
[[ "$CAPE_ROOT" == '/opt/CAPE test/$root' ]]
[[ "$CAPE_MACHINE" == 'win test' ]]
[[ "$CAPE_DOMAIN" == 'actual-domain' ]]
[[ "$CAPE_GUEST_CONTROL_IP" == '192.0.2.100' ]]
[[ "$CAPE_RESULTSERVER_IP" == '192.0.2.1' ]]
[[ "$INETSIM_SERVER_IP" == '198.51.100.2' ]]
[[ "$ANALYSIS_GUEST_IP" == '198.51.100.10' ]]
[[ "$CAPTURE_INTERFACE" == 'capeisim7' ]]

# RC28 regression: modern CAPE has a network template but no legacy INetSim
# template/tag modules. Candidate generation must be additive and succeed.
RUNTIME="$TMP/runtime"
CAPE="$TMP/cape"
cp -a "$EXTENSION_BUNDLED_ROOT" "$RUNTIME"
mkdir -p "$CAPE/web/templates/analysis/network" "$CAPE/web/analysis/templatetags"
touch "$CAPE/web/analysis/templatetags/__init__.py"
cat >"$CAPE/web/templates/analysis/network/index.html" <<'EOF'
{% if network.pcap_sha256 %}<div>PCAP</div>{% endif %}
<ul class="nav" id="networkTabs" role="tablist">
  <li class="nav-item"><a href="#network_hosts_tab">Hosts</a></li>
</ul>
<div class="tab-content">
  <div id="network_hosts_tab">hosts</div>
</div>
EOF
cat >"$RUNTIME/src/inetsim-vm.conf" <<EOF
CAPE_ROOT=$CAPE
CAPE_MACHINE=win10
CAPE_DOMAIN=win10
CAPE_GUEST_CONTROL_IP=192.0.2.100
CAPE_RESULTSERVER_IP=192.0.2.1
INETSIM_SERVER_IP=198.51.100.2
ANALYSIS_GUEST_IP=198.51.100.10
CAPTURE_INTERFACE=capeisim7
EOF

python3 "$RUNTIME/scripts/prepare_install_candidate.py"
C="$RUNTIME/build/install-candidate"
[[ "$(cat "$C/INSTALL-LAYOUT")" == modern-network-template-v1 ]]
grep -Fq 'CAPE_INETSIM_VM_ROUTE_NONE_V1' "$C/web/templates/analysis/network/index.html"
grep -Fq 'CAPE_INETSIM_VM_MODERN_NETWORK_V1' "$C/web/templates/analysis/network/index.html"
grep -Fq '{% load inetsim_vm_tags %}' "$C/web/templates/analysis/network/index.html"
grep -Fq 'network_inetsim-tab' "$C/web/templates/analysis/network/index.html"
grep -Fq 'network_inetsim_tab' "$C/web/templates/analysis/network/index.html"
grep -Fq 'analysis|inetsim_vm_active' "$C/web/templates/analysis/network/index.html"
! grep -Fq 'network|inetsim_vm_active' "$C/web/templates/analysis/network/index.html"
grep -Fq 'route != "inetsim"' "$C/web/analysis/templatetags/inetsim_vm_tags.py"
[[ -f "$C/web/analysis/templatetags/inetsim_vm_tags.py" ]]
[[ -f "$C/web/templates/analysis/network/_inetsim_vm_visual.html" ]]
[[ -f "$C/web/analysis/inetsim_vm_logic.py" ]]
[[ ! -e "$C/web/analysis/views.py" ]]
python3 -m py_compile "$C/web/analysis/inetsim_vm_logic.py" "$C/web/analysis/templatetags/inetsim_vm_tags.py"

# Rollback manifest must include the modified network template and every new file.
for rel in   web/templates/analysis/network/index.html   web/analysis/inetsim_vm_logic.py   web/analysis/templatetags/inetsim_vm_tags.py   web/templates/analysis/network/_inetsim_vm_visual.html
do
  grep -Fq ""$rel"" "$EXTENSION_BUNDLED_ROOT/scripts/backup.sh"
done
! grep -Fq '"web/analysis/views.py"' "$EXTENSION_BUNDLED_ROOT/scripts/backup.sh"

# A same-version directory left by a failed run is not trusted unless it owns
# a rollback reference; it must be refreshed from the bundled runtime.
AD_LOG_ROOT="$TMP/logs"
DEPLOYMENT_ID=test-extension-refresh
mkdir -p "$AD_LOG_ROOT"
EXTENSION_ROOT="$TMP/stale-extension"
mkdir -p "$EXTENSION_ROOT"
printf '1.0.2\n' >"$EXTENSION_ROOT/VERSION"
printf '#!/bin/sh\nexit 99\n' >"$EXTENSION_ROOT/install.sh"
chmod +x "$EXTENSION_ROOT/install.sh"
extension_fetch_extract
cmp "$EXTENSION_ROOT/install.sh" "$EXTENSION_BUNDLED_ROOT/install.sh"
grep -Fq 'refreshing-unowned-runtime' "$AD_LOG_ROOT/${DEPLOYMENT_ID}-extension-materialize.log"
grep -Fq 'materialized=yes' "$AD_LOG_ROOT/${DEPLOYMENT_ID}-extension-materialize.log"

echo '[PASS] vendored extension v1.0.2 supports modern CAPE, managed preflight, and stale-runtime refresh'

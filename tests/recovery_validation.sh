#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/targets.sh"
source "$ROOT/lib/validate.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
AD_BACKUP_ROOT="$TMP/backups"
DEPLOYMENT_ID=test-deployment
DOMAIN=testvm
SAFETY_SNAPSHOT=pre-safe
EXTENSION_ROOT="$TMP/extension"
CAPE_TARGETS_JSON='[{"section":"win","label":"win","domain":"testvm","safety_snapshot":"pre-safe","phase":"cape-configured"}]'
CAPE_TARGETS_COUNT=1
targets_bind 0

for rel in modules/auxiliary/sniffer.py conf/auxiliary.conf conf/kvm.conf conf/processing.conf conf/routing.conf; do
  p="$AD_BACKUP_ROOT/$DEPLOYMENT_ID/$rel"
  mkdir -p "$(dirname "$p")"
  printf 'protected %s\n' "$rel" >"$p"
  sha256sum "$p" >"$p.sha256"
done

mkdir -p "$EXTENSION_ROOT/scripts"
cat >"$EXTENSION_ROOT/scripts/rollback.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == --check ]]
exit 0
EOF
chmod +x "$EXTENSION_ROOT/scripts/rollback.sh"

state_has_owned_kind() {
  [[ "$1" == cape-file || "$1" == extension ]]
}
state_resource_owned() {
  [[ "$1" == snapshot && "$2" == "$DOMAIN:$SAFETY_SNAPSHOT" ]]
}
virsh() {
  [[ "$1" == snapshot-info && "$2" == "$DOMAIN" && "$3" == "$SAFETY_SNAPSHOT" ]]
}

validate_recovery_assets

printf 'tamper\n' >>"$AD_BACKUP_ROOT/$DEPLOYMENT_ID/conf/kvm.conf"
if validate_recovery_assets >/dev/null 2>&1; then
  echo 'recovery validator accepted tampered CAPE backup' >&2
  exit 1
fi

grep -Fq 'A different AutoDeploy release is already committed' "$ROOT/lib/deploy.sh"
grep -Fq 'Roll it back with that exact release before installing this route-separated release' "$ROOT/lib/deploy.sh"

# Ordinary deployment remains rollback-first across releases. The only supported
# in-place RC44 conversion is the explicit, ownership-gated --repair path.
grep -Fq 'Owned legacy route-global deployment detected' "$ROOT/bin/cape-inetsim-repair"
grep -Fq 'source "$ROOT/lib/runtime-patches.sh"' "$ROOT/bin/cape-inetsim-repair"
grep -Fq 'lib/cuckoo/core/startup.py' "$ROOT/lib/runtime-patches.sh"
grep -Fq 'CAPE_INETSIM_AUTODEPLOY_INETSIM_NO_NAT_V1' "$ROOT/tools/patch_cape_runtime.py"
python3 - "$ROOT/bin/cape-inetsim-repair" <<'PY'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
patches=s.index('source "$ROOT/lib/runtime-patches.sh"')
configure=s.index('source "$ROOT/lib/cape-configure.sh"')
assert patches < configure, "standalone repair must source runtime-patches.sh before cape-configure.sh"
PY
grep -Fq 'Legacy route-global CAPE patch is not transaction-owned' "$ROOT/bin/cape-inetsim-repair"
grep -Fq 'Legacy route-global web extension is not transaction-owned' "$ROOT/bin/cape-inetsim-repair"
python3 - "$ROOT/bin/cape-inetsim-repair" <<'PY'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
detect=s.index("Owned legacy route-global deployment detected")
maintenance=s.index("A legacy RC44 migration changes routing policy")
firewall=s.index("\nfirewall_apply\n", maintenance)
cape_mutation=s.index("\ncape_configure_inetsim\n", firewall)
extension=s.index("\nextension_upgrade_route_gated\n", cape_mutation)
validate=s.index("\nvalidate_deployment_structural\n", extension)
promote=s.index("Promote provenance only after every migration/repair gate succeeds", validate)
commit=s.index("\nstate_set_phase committed\n", promote)
assert detect < maintenance < firewall < cape_mutation < extension < validate < promote < commit
PY

echo '[PASS] recovery assets are protected; deploy is rollback-first and explicit RC44 repair migration is ownership-gated'

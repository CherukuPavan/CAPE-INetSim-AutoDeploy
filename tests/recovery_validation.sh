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

echo '[PASS] recovery assets and checksums are required for structural acceptance'

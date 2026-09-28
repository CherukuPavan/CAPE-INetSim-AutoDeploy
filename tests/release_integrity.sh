#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required=(
  INSTALL.md TROUBLESHOOTING.md ARCHITECTURE.md RECOVERY.md
  appliance/gui-enable.sh
  appliance/guest-configure.sh
  appliance/image-rootfs-prepare.sh
  appliance/build/render-manifest.py
  appliance/build/verify-artifact.sh
  release/bootstrap-template.sh
  .github/workflows/appliance-build.yml
  .github/workflows/prepare-release.yml
  .github/workflows/publish-public-release.yml
  lib/runtime.sh lib/rooter.sh lib/inventory.sh lib/decision.sh
)

for rel in "${required[@]}"; do
  [[ -s "$ROOT/$rel" ]] || { echo "[FAIL] missing release/runtime dependency: $rel" >&2; exit 1; }
done

grep -Fq 'name: Build generalized INetSim appliance' "$ROOT/.github/workflows/appliance-build.yml"
grep -Fq 'actions/workflows/appliance-build.yml' "$ROOT/.github/workflows/publish-public-release.yml"
grep -Fq 'source/appliance/gui-enable.sh' "$ROOT/.github/workflows/publish-public-release.yml"
grep -Fq 'source/appliance/build/render-manifest.py' "$ROOT/.github/workflows/publish-public-release.yml"
grep -Fq 'source/appliance/build/verify-artifact.sh' "$ROOT/.github/workflows/publish-public-release.yml"
grep -Fq 'source/release/bootstrap-template.sh' "$ROOT/.github/workflows/publish-public-release.yml"

python3 -m py_compile "$ROOT/appliance/build/render-manifest.py"
bash -n "$ROOT/appliance/gui-enable.sh"
bash -n "$ROOT/appliance/build/verify-artifact.sh"
bash -n "$ROOT/release/bootstrap-template.sh"

echo "[PASS] release integrity"

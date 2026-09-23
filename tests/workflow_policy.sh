#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI="$ROOT/.github/workflows/ci.yml"
AP="$ROOT/.github/workflows/appliance-build.yml"
REL="$ROOT/.github/workflows/prepare-release.yml"
PUB="$ROOT/.github/workflows/publish-public-release.yml"

grep -q '^  pull_request:' "$CI"
grep -A4 '^  push:' "$CI" | grep -q -- '- main'
grep -q 'cancel-in-progress: true' "$CI"

grep -q '^  workflow_dispatch:' "$AP"
grep -A8 '^  push:' "$AP" | grep -q 'dev/v1-orchestrator-hardening'
! grep -A8 '^  push:' "$AP" | grep -q 'paths:'
! grep -q '^  pull_request:' "$AP"
grep -q 'cancel-in-progress: true' "$AP"
grep -Fq 'TAG="candidate-${GITHUB_SHA}"' "$AP"
grep -q 'candidate-provenance.json' "$AP"
grep -Fq '},indent=2)+"\n")' "$AP"
! grep -Fq '},indent=2)+"\\n")' "$AP"
grep -Fq 'gh release create "$TAG"' "$AP"
grep -Fq 'candidate_handoff_outcome=' "$AP"
grep -A3 '^permissions:' "$AP" | grep -Fq 'contents: write'
grep -q 'No candidate is publishable' "$AP"
grep -q 'exit 1' "$AP"

for wf in "$CI" "$AP" "$REL" "$PUB"; do
  ! grep -Eq 'uses:[[:space:]]+actions/(checkout|upload-artifact|cache)@v[0-9]+' "$wf"
done
grep -Fq 'actions/checkout@11d5960a326750d5838078e36cf38b85af677262' "$CI"
grep -Fq 'actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830' "$AP"
grep -Fq 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' "$AP"
grep -Fq 'actions/checkout@11d5960a326750d5838078e36cf38b85af677262' "$REL"
grep -Fq 'libguestfs-tools qemu-utils qemu-system-x86 cloud-image-utils' "$REL"
grep -Fq 'chmod a+r /boot/vmlinuz-* /boot/initrd.img-*' "$REL"
grep -Fq 'LIBGUESTFS_BACKEND: direct' "$REL"
! grep -Fq 'cp "$MANIFEST" "$DIST/appliance-manifest.json"' "$REL"

grep -Fq 'CherukuPavan/CAPE-INetSim-AutoDeploy-Releases' "$PUB"
grep -Fq 'PUBLIC_RELEASE_TOKEN' "$PUB"
grep -Fq 'PRIVATE_REPO: CherukuPavan/CAPE-INetSim-AutoDeploy' "$PUB"
grep -Fq 'Release-only allowlist' "$PUB"
grep -Fq 'host-specific lab identifier found in public runtime' "$PUB"
grep -Fq 'CAPE-INetSim-AutoDeploy-$VERSION.tar.gz' "$PUB"
grep -Fq 'actions/checkout@11d5960a326750d5838078e36cf38b85af677262' "$PUB"
grep -Fq 'release/PUBLIC_RELEASE_REQUEST.json' "$PUB"
grep -Fq 'source/vendor/CAPE-INetSim-VM-Extension-v1.0.2/' "$PUB"
grep -Fq 'private extension repository reference leaked into public runtime' "$PUB"
grep -Fq 'install -m 0755 source/appliance/guest-configure.sh "$ROOT/appliance/guest-configure.sh"' "$PUB"
grep -Fq 'runtime guest configurator does not match release source' "$PUB"
grep -Fq 'TAG="candidate-$SOURCE_SHA"' "$PUB"
grep -Fq 'gh release download "$TAG"' "$PUB"
grep -Fq 'private candidate handoff tag does not resolve to requested source SHA' "$PUB"

echo '[PASS] workflow policy keeps appliance candidates exact-source-bound and pins third-party action commits'

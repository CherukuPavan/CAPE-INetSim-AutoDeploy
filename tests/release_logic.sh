#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOT="$ROOT/release/bootstrap-template.sh"
WF="$ROOT/.github/workflows/prepare-release.yml"

[[ ! -e "$ROOT/release/CANDIDATE-v1.0.0.json" ]]

bash -n "$BOOT"
grep -Fq 'https://github.com/$REPO/releases/download/$TAG/$SOURCE_NAME' "$BOOT"
grep -Fq 'sha256sum -c' "$BOOT"
grep -Fq 'curl --fail --silent --show-error --location' "$BOOT"
grep -Fq 'invalid embedded source SHA-256' "$BOOT"
grep -Fq 'invalid embedded source commit' "$BOOT"
grep -Fq 'unsafe path in release source bundle' "$BOOT"
grep -Fq 'unexpected top-level path in release source bundle' "$BOOT"
grep -Fq -- '--no-same-owner --no-same-permissions' "$BOOT"
grep -Fq 'command -v python3' "$BOOT"
! grep -Fq 'trap - EXIT' "$BOOT"
! grep -Fq 'exec "$ROOT/install"' "$BOOT"
! grep -Fq '/archive/refs/heads/main' "$BOOT"
! grep -Fq '/archive/refs/heads/main' "$ROOT/install"
grep -Fq "not a trusted network bootstrap" "$ROOT/install"

grep -q '^  workflow_dispatch:' "$WF"
! grep -q '^  push:' "$WF"
! grep -q '^  pull_request:' "$WF"
grep -q 'candidate_run_id:' "$WF"
grep -q 'source_sha:' "$WF"
[[ "$(grep -Fc 'ref: ${{ inputs.source_sha }}' "$WF")" -ge 2 ]]
grep -q 'Checkout exact candidate release tooling' "$WF"
grep -q 'candidate workflow source SHA does not match release source SHA' "$WF"
grep -q 'stable v1.0.0 cannot be published while the repository is private' "$WF"
grep -q 'gh run download' "$WF"
grep -q 'verify-artifact.sh' "$WF"
grep -q 'gzip -dc "$PKG" >"$RAW"' "$WF"
grep -q 'render-manifest.py' "$WF"
grep -q 'sha256sum -c' "$BOOT"
grep -q 'Upload release package preview' "$WF"
grep -q 'Create draft GitHub release' "$WF"
grep -q -- '--draft' "$WF"
grep -q 'refusing to overwrite release assets' "$WF"
grep -q 'refusing to reuse or move an immutable release tag' "$WF"
grep -q 'created release tag does not resolve to the verified source commit' "$WF"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TAG=v1.0.0-rc.9
NAME=CAPE-INetSim-AutoDeploy-1.0.0-rc.9.tar.gz
SHA=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
COMMIT=0123456789abcdef0123456789abcdef01234567
python3 - "$BOOT" "$TMP/install" "$TAG" "$NAME" "$SHA" "$COMMIT" <<'PY'
import pathlib,sys
src,out,tag,name,sha,commit=sys.argv[1:]
s=pathlib.Path(src).read_text()
s=s.replace("@@TAG@@",tag).replace("@@SOURCE_NAME@@",name).replace("@@SOURCE_SHA256@@",sha).replace("@@SOURCE_COMMIT@@",commit)
assert "@@" not in s
pathlib.Path(out).write_text(s)
PY
bash -n "$TMP/install"
grep -Fq 'TAG="v1.0.0-rc.9"' "$TMP/install"
grep -Fq "SOURCE_NAME=\"$NAME\"" "$TMP/install"
grep -Fq "SOURCE_SHA256=\"$SHA\"" "$TMP/install"

echo '[PASS] release packaging is manual, exact-SHA-bound and checksum-pinned'

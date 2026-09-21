#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI="$ROOT/.github/workflows/ci.yml"
AP="$ROOT/.github/workflows/appliance-build.yml"
REL="$ROOT/.github/workflows/prepare-release.yml"

grep -q '^  pull_request:' "$CI"
grep -A4 '^  push:' "$CI" | grep -q -- '- main'
grep -q 'cancel-in-progress: true' "$CI"

grep -q '^  workflow_dispatch:' "$AP"
grep -A8 '^  push:' "$AP" | grep -q 'dev/v1-orchestrator-hardening'
grep -A10 '^  push:' "$AP" | grep -q 'appliance/\*\*'
! grep -q '^  pull_request:' "$AP"
grep -q 'cancel-in-progress: true' "$AP"
grep -q 'cape-inetsim-appliance-v1.0.0-evidence' "$AP"
grep -q 'candidate-provenance.json' "$AP"
[[ "$(grep -Fc 'retention-days: 30' "$AP")" -ge 2 ]]
grep -q 'No candidate is publishable' "$AP"
grep -q 'exit 1' "$AP"

for wf in "$CI" "$AP" "$REL"; do
  ! grep -Eq 'uses:[[:space:]]+actions/(checkout|upload-artifact|cache)@v[0-9]+' "$wf"
done
grep -Fq 'actions/checkout@11d5960a326750d5838078e36cf38b85af677262' "$CI"
grep -Fq 'actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830' "$AP"
grep -Fq 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' "$AP"
grep -Fq 'actions/checkout@11d5960a326750d5838078e36cf38b85af677262' "$REL"

echo '[PASS] workflow policy avoids duplicate/noisy builds and pins third-party action commits'

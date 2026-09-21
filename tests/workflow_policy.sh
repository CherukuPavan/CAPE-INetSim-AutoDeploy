#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI="$ROOT/.github/workflows/ci.yml"
AP="$ROOT/.github/workflows/appliance-build.yml"

grep -q '^  pull_request:' "$CI"
grep -A4 '^  push:' "$CI" | grep -q -- '- main'
grep -q 'cancel-in-progress: true' "$CI"

grep -q '^  workflow_dispatch:' "$AP"
grep -A8 '^  push:' "$AP" | grep -q 'dev/v1-orchestrator-hardening'
grep -A10 '^  push:' "$AP" | grep -q 'appliance/\*\*'
! grep -q '^  pull_request:' "$AP"
grep -q 'cancel-in-progress: true' "$AP"

echo '[PASS] workflow policy avoids duplicate/noisy PR appliance builds'

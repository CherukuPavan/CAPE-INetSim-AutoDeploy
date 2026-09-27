#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export AD_STATE_ROOT="$TMP/state"
export AD_STATE_FILE="$AD_STATE_ROOT/state.env"
export AD_RESOURCE_LEDGER="$AD_STATE_ROOT/resources.tsv"
export AD_BACKUP_ROOT="$AD_STATE_ROOT/backups"
export AD_GENERATED_ROOT="$AD_STATE_ROOT/generated"
export AD_LOG_ROOT="$AD_STATE_ROOT/logs"
export AD_LOCK_FILE="$TMP/lock"

source "$ROOT/lib/common.sh"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/decision.sh"
source "$ROOT/lib/cape.sh"

virsh(){ return 1; }

expect_eq(){
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "[FAIL] $label: expected='$expected' actual='$actual'" >&2
    exit 1
  fi
}

# Machine A: completely fresh host.
deployment_decision_classify
expect_eq "$DEPLOYMENT_DECISION" fresh "fresh-machine decision"

# Machine B: old committed AutoDeploy release -> automatic upgrade.
state_init_paths
cat >"$AD_STATE_FILE" <<EOF
STATE_SCHEMA=3
DEPLOYMENT_ID=old-deployment
DEPLOYMENT_PHASE=committed
RELEASE_TAG=v1.0.0-rc.64
RELEASE_SOURCE_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
chmod 0600 "$AD_STATE_FILE"
export CAPE_INETSIM_RELEASE_SOURCE_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
deployment_decision_classify
expect_eq "$DEPLOYMENT_DECISION" upgrade "existing-release decision"

# Broken previous repair -> automatic repair path.
sed -i 's/^DEPLOYMENT_PHASE=.*/DEPLOYMENT_PHASE=repair-incomplete/' "$AD_STATE_FILE"
deployment_decision_classify
expect_eq "$DEPLOYMENT_DECISION" repair "broken-installation decision"

# Machine C: custom CAPE path, custom unit names, no cape.service assumption.
CUSTOM="$TMP/Custom CAPE Tree"
mkdir -p "$CUSTOM/conf" "$CUSTOM/utils"
: >"$CUSTOM/conf/kvm.conf"
: >"$CUSTOM/conf/cuckoo.conf"
cat >"$CUSTOM/utils/rooter.py" <<'PY'
def inetsim_enable(): pass
PY

systemctl(){
  case "$1" in
    list-units)
      printf '%s\n' sandbox-scheduler.service sandbox-router.service custom-ui.service custom-processing.service
      ;;
    list-unit-files)
      printf '%s enabled\n' sandbox-scheduler.service sandbox-router.service custom-ui.service custom-processing.service
      ;;
    cat) return 0 ;;
    is-active)
      [[ "${2:-}" == sandbox-scheduler.service || "${2:-}" == sandbox-router.service ]] && return 0
      return 3
      ;;
    show)
      local unit="$2" prop=""
      while (($#)); do [[ "$1" == -p ]] && { prop="$2"; break; }; shift; done
      case "$unit:$prop" in
        sandbox-scheduler.service:WorkingDirectory|sandbox-router.service:WorkingDirectory|custom-ui.service:WorkingDirectory|custom-processing.service:WorkingDirectory)
          printf '%s\n' "$CUSTOM" ;;
        sandbox-scheduler.service:ExecStart) printf '{ argv[]=/weird/venv/bin/python cuckoo.py ; }\n' ;;
        sandbox-router.service:ExecStart) printf '{ argv[]=/weird/venv/bin/python %s/utils/rooter.py ; }\n' "$CUSTOM" ;;
        custom-ui.service:ExecStart) printf '{ argv[]=/weird/venv/bin/python manage.py runserver ; }\n' ;;
        custom-processing.service:ExecStart) printf '{ argv[]=/weird/venv/bin/python utils/process.py ; }\n' ;;
        *:User) printf 'sandboxuser\n' ;;
        *) printf '\n' ;;
      esac
      ;;
    *) return 0 ;;
  esac
}

CAPE_ROOT=""
DISCOVERY_ERRORS=()
discover_cape_root
expect_eq "$CAPE_ROOT" "$CUSTOM" "custom CAPE root"
discover_cape_services
expect_eq "${CAPE_SCHEDULER_SERVICE:-}" sandbox-scheduler.service "scheduler service discovery"
expect_eq "${CAPE_ROOTER_SERVICE:-}" sandbox-router.service "Rooter service discovery"
expect_eq "${CAPE_WEB_SERVICE:-}" custom-ui.service "web service discovery"
expect_eq "${CAPE_PROCESSOR_SERVICE:-}" custom-processing.service "processor service discovery"
expect_eq "${CAPE_ROOTER_EXECUTABLE:-}" "$CUSTOM/utils/rooter.py" "Rooter executable discovery"

echo "[PASS] production decision/discovery matrix covers fresh, upgrade, broken and custom-layout hosts"

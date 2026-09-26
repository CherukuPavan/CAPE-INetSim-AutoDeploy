#!/usr/bin/env bash

# ============================================================
# CAPE Ubuntu-VM INetSim Extension
# Production installation engine
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &&
    pwd
)"

EXT_ROOT="$(
    cd -- "$SCRIPT_DIR/.." &&
    pwd
)"

CONFIG_FILE="$EXT_ROOT/src/inetsim-vm.conf"
CANDIDATE="$EXT_ROOT/build/install-candidate"

MODE="${1:---preflight}"

CAPE_WEB_SERVICE="${CAPE_WEB_SERVICE:-cape-web}"

CAPE_SERVICE_USER=""
CAPE_SERVICE_GROUP=""
CAPE_WEB_PID=""
CAPE_PYTHON=""

RUNTIME_DIR=""

AUTO_BACKUP=""
INSTALL_STARTED=0


pass() {
    printf '[PASS] %s\n' "$1"
}


info() {
    printf '[INFO] %s\n' "$1"
}


fail() {
    printf '[FAIL] %s\n' "$1"
}


cleanup_runtime_dir() {

    local runtime="${RUNTIME_DIR:-}"

    [[ -z "$runtime" ]] && return 0

    # Never allow cleanup to remove an arbitrary path.
    case "$runtime" in

        /tmp/cape-inetsim-production-runtime.*)
            sudo rm -rf -- "$runtime" >/dev/null 2>&1 || true
            ;;

        *)
            printf '[WARN] Refusing unsafe runtime cleanup path: %s\n' \
                "$runtime" >&2
            ;;

    esac

    RUNTIME_DIR=""
}


prepare_runtime_dir() {

    cleanup_runtime_dir

    RUNTIME_DIR="$(
        mktemp -d \
            /tmp/cape-inetsim-production-runtime.XXXXXXXX
    )" || {
        fail "Unable to create unique Django runtime directory"
        return 1
    }

    if ! sudo chown \
        "$CAPE_SERVICE_USER:$CAPE_SERVICE_GROUP" \
        "$RUNTIME_DIR"; then

        fail "Unable to set Django runtime directory ownership"
        cleanup_runtime_dir
        return 1

    fi

    if ! sudo chmod 755 "$RUNTIME_DIR"; then

        fail "Unable to set Django runtime directory permissions"
        cleanup_runtime_dir
        return 1

    fi

    pass "Unique Django runtime directory prepared"
}


# Remove the temporary runtime directory on every normal or
# abnormal script exit. The ERR trap remains independent.
trap cleanup_runtime_dir EXIT


# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

if [[ ! -r "$CONFIG_FILE" ]]; then
    fail "Configuration file missing: $CONFIG_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"


if [[ ! -d "${CAPE_ROOT:-}" ]]; then
    fail "CAPE_ROOT does not exist: ${CAPE_ROOT:-<empty>}"
    exit 1
fi


# ------------------------------------------------------------
# Discover CAPE's actual service account and Python runtime.
# ------------------------------------------------------------

discover_cape_runtime() {

    if ! systemctl cat "$CAPE_WEB_SERVICE" >/dev/null 2>&1; then
        fail "CAPE web service not found: $CAPE_WEB_SERVICE"
        return 1
    fi

    CAPE_SERVICE_USER="$(
        systemctl show "$CAPE_WEB_SERVICE" \
            --property=User \
            --value
    )"

    if [[ -z "$CAPE_SERVICE_USER" ]]; then
        fail "Unable to determine CAPE web service account"
        return 1
    fi

    CAPE_SERVICE_GROUP="$(
        id -gn "$CAPE_SERVICE_USER"
    )"

    CAPE_WEB_PID="$(
        systemctl show "$CAPE_WEB_SERVICE" \
            --property=MainPID \
            --value
    )"

    # CAPE_INETSIM_RUNTIME_DISCOVERY_V2
    #
    # Preserve the interpreter path exactly as cape-web uses it.
    # readlink /proc/<pid>/exe would resolve a virtualenv Python
    # symlink to /usr/bin/python, losing the CAPE environment.
    CAPE_PYTHON=""

    if [[ "$CAPE_WEB_PID" =~ ^[0-9]+$ ]] \
       && (( CAPE_WEB_PID > 0 )); then

        CAPE_PYTHON="$(
            ps -p "$CAPE_WEB_PID" -o args= \
                2>/dev/null |
            awk '{print $1}' |
            head -1
        )"

    fi

    if [[ -z "$CAPE_PYTHON" ]]; then

        CAPE_PYTHON="$(
            systemctl cat "$CAPE_WEB_SERVICE" |
            sed -n \
                's/^ExecStart=\([^[:space:]]*python[^[:space:]]*\).*/\1/p' |
            head -1
        )"

    fi

    if [[ -z "$CAPE_PYTHON" ]]; then
        fail "Unable to discover CAPE Python interpreter"
        return 1
    fi

    if ! sudo -u "$CAPE_SERVICE_USER" \
        test -x "$CAPE_PYTHON"; then

        fail "CAPE service account cannot execute $CAPE_PYTHON"
        return 1

    fi

    pass "CAPE service account: $CAPE_SERVICE_USER"
    pass "CAPE Python discovered: $CAPE_PYTHON"
}


# ------------------------------------------------------------
# Build candidate from CURRENT CAPE source.
# ------------------------------------------------------------

build_candidate() {

    if ! python3 \
        "$EXT_ROOT/scripts/prepare_install_candidate.py"; then

        fail "Production candidate generation failed"
        return 1

    fi

    if [[ ! -d "$CANDIDATE" ]]; then
        fail "Candidate directory was not created"
        return 1
    fi

    pass "Production candidate generated from current CAPE"
}


# ------------------------------------------------------------
# Compile candidate.
# ------------------------------------------------------------

compile_candidate() {

    if python3 -m py_compile \
        "$CANDIDATE/web/analysis/inetsim_vm_logic.py" \
        "$CANDIDATE/web/analysis/templatetags/inetsim_vm_tags.py"; then

        pass "Candidate Python files compile"

    else

        fail "Candidate Python compilation failed"
        return 1

    fi
}


# ------------------------------------------------------------
# Validate candidate using CAPE's actual Django runtime.
# ------------------------------------------------------------

runtime_gate() {

    prepare_runtime_dir

    sudo install \
        -o "$CAPE_SERVICE_USER" \
        -g "$CAPE_SERVICE_GROUP" \
        -m 644 \
        "$CANDIDATE/web/analysis/templatetags/inetsim_vm_tags.py" \
        "$RUNTIME_DIR/inetsim_vm_tags.py"

    sudo install \
        -o "$CAPE_SERVICE_USER" \
        -g "$CAPE_SERVICE_GROUP" \
        -m 644 \
        "$CANDIDATE/web/analysis/inetsim_vm_logic.py" \
        "$RUNTIME_DIR/inetsim_vm_logic.py"

    sudo install \
        -o "$CAPE_SERVICE_USER" \
        -g "$CAPE_SERVICE_GROUP" \
        -m 644 \
        "$CANDIDATE/web/templates/analysis/network/_inetsim_vm_visual.html" \
        "$RUNTIME_DIR/_inetsim_vm_visual.html"

    sudo install \
        -o "$CAPE_SERVICE_USER" \
        -g "$CAPE_SERVICE_GROUP" \
        -m 755 \
        "$EXT_ROOT/tests/test_django_candidate_ui.py" \
        "$RUNTIME_DIR/test_django_candidate_ui.py"

    if ! sudo -u "$CAPE_SERVICE_USER" \
        "$CAPE_PYTHON" \
        -m py_compile \
        "$RUNTIME_DIR/test_django_candidate_ui.py"; then

        fail "Candidate Django validator compilation failed"
        return 1

    fi

    # CAPE_INETSIM_RUNTIME_CAPTURE_V2
    #
    # Capture validator output directly. This avoids shell
    # redirection trying to create runtime.log as the login user
    # inside the cape-owned temporary directory.
    local runtime_output=""

    if ! runtime_output="$(
        sudo -u "$CAPE_SERVICE_USER" \
            "$CAPE_PYTHON" \
            "$RUNTIME_DIR/test_django_candidate_ui.py" \
            2>&1
    )"; then

        printf '%s\n' "$runtime_output"

        fail "Candidate failed CAPE Django runtime validation"
        return 1

    fi

    if ! grep -qx \
        'STATUS: UNIVERSAL CAPE DJANGO CANDIDATE VALIDATION PASSED' \
        <<< "$runtime_output"; then

        printf '%s\n' "$runtime_output"

        fail "Expected universal Django PASS status was not found"
        return 1

    fi

    pass "Candidate passed CAPE Django runtime validation"
}



validate_state_manifest() {

    local state_file="$1"
    local cape_root="$2"
    local backup_dir="$3"

    local state=""
    local relative=""
    local canonical_root=""
    local canonical_backup_root=""
    local canonical_target=""
    local canonical_source=""

    declare -A seen=()

    # Require exactly:
    #
    #   STATE<TAB>FILE
    #   EXISTED<TAB>relative/path
    #   MISSING<TAB>relative/path
    #
    if ! awk -F '\t' '
        NR == 1 {
            if ($0 != "STATE\tFILE")
                exit 1
            next
        }

        NF != 2 {
            exit 1
        }

        $1 != "EXISTED" && $1 != "MISSING" {
            exit 1
        }

        $2 == "" {
            exit 1
        }

        END {
            if (NR < 2)
                exit 1
        }
    ' "$state_file"; then

        fail "Rollback state manifest structure is invalid"
        return 1

    fi


    canonical_root="$(
        python3 -c \
        'import os,sys; print(os.path.realpath(sys.argv[1]))' \
        "$cape_root"
    )" || {
        fail "Could not canonicalize CAPE_ROOT"
        return 1
    }


    canonical_backup_root="$(
        python3 -c \
        'import os,sys; print(os.path.realpath(sys.argv[1]))' \
        "$backup_dir"
    )" || {
        fail "Could not canonicalize backup directory"
        return 1
    }


    if [[ "$canonical_root" == "/" ]]; then

        fail "Unsafe CAPE_ROOT detected: /"
        return 1

    fi


    while IFS=$'\t' read -r state relative; do

        [[ "$state" == "STATE" ]] && continue


        # CAPE source paths used by this extension are ordinary
        # relative POSIX paths. Reject unexpected characters.
        if [[ ! "$relative" =~ ^[A-Za-z0-9._/-]+$ ]]; then

            fail "Unsafe rollback path characters: $relative"
            return 1

        fi


        # Reject absolute paths, empty components, leading ./,
        # trailing slash, and explicit . or .. path components.
        if [[ "$relative" == /* \
           || "$relative" == ./* \
           || "$relative" == */ \
           || "$relative" == *//* \
           || "$relative" =~ (^|/)\.\.?(/|$) ]]; then

            fail "Unsafe rollback relative path: $relative"
            return 1

        fi


        if [[ -n "${seen[$relative]+x}" ]]; then

            fail "Duplicate rollback path: $relative"
            return 1

        fi

        seen["$relative"]=1


        canonical_target="$(
            python3 -c \
            'import os,sys; print(os.path.realpath(sys.argv[1]))' \
            "$cape_root/$relative"
        )" || {
            fail "Could not canonicalize CAPE target: $relative"
            return 1
        }


        case "$canonical_target" in

            "$canonical_root"/*)
                ;;

            *)
                fail "Rollback target escapes CAPE_ROOT: $relative"
                return 1
                ;;

        esac


        if [[ "$state" == "EXISTED" ]]; then

            canonical_source="$(
                python3 -c \
                'import os,sys; print(os.path.realpath(sys.argv[1]))' \
                "$backup_dir/$relative"
            )" || {
                fail "Could not canonicalize backup source: $relative"
                return 1
            }


            case "$canonical_source" in

                "$canonical_backup_root"/*)
                    ;;

                *)
                    fail "Backup source escapes backup directory: $relative"
                    return 1
                    ;;

            esac

        fi

    done < "$state_file"


    if [[ "${#seen[@]}" -eq 0 ]]; then

        fail "Rollback state manifest contains no managed paths"
        return 1

    fi


    pass "Rollback state manifest structure and paths are safe"
    return 0
}


# ------------------------------------------------------------
# Automatic failure rollback.
# ------------------------------------------------------------

automatic_restore() {

    local backup_dir="$1"
    local state_file="$backup_dir/FILE-STATE.tsv"
    local checksum_file="$backup_dir/SHA256SUMS"

    echo
    echo "============================================================"
    echo " AUTOMATIC INSTALLATION ROLLBACK"
    echo "============================================================"

    if [[ ! -s "$state_file" ]]; then
        fail "Rollback state manifest missing: $state_file"
        return 1
    fi

    if [[ ! -s "$checksum_file" ]]; then
        fail "Rollback checksum manifest missing: $checksum_file"
        return 1
    fi

    if ! (
        cd "$backup_dir" &&
        sha256sum -c SHA256SUMS >/dev/null 2>&1
    ); then

        fail "Automatic rollback backup checksum validation failed"
        return 1

    fi

    if ! validate_state_manifest         "$state_file"         "$CAPE_ROOT"         "$backup_dir"; then

        fail "Automatic rollback state manifest validation failed"
        return 1

    fi

    while IFS=$'\t' read -r state relative; do

        [[ "$state" == "STATE" ]] && continue
        [[ -z "${relative:-}" ]] && continue

        target="$CAPE_ROOT/$relative"

        case "$state" in

            EXISTED)

                if [[ ! -f "$backup_dir/$relative" ]]; then
                    fail "Backup copy missing: $relative"
                    continue
                fi

                mkdir -p "$(dirname "$target")"

                cp -a \
                    "$backup_dir/$relative" \
                    "$target"

                echo "[RESTORED] $relative"

                ;;

            MISSING)

                rm -f "$target"

                echo "[REMOVED] $relative"

                ;;

        esac

    done < "$state_file"

    systemctl restart "$CAPE_WEB_SERVICE" || true

    echo
    echo "Automatic rollback completed."
}


on_error() {

    rc=$?

    trap - ERR

    if [[ "$INSTALL_STARTED" -eq 1 \
       && -n "$AUTO_BACKUP" ]]; then

        set +e

        automatic_restore "$AUTO_BACKUP"

        set -e

    fi

    echo
    fail "Production installation did not complete"

    exit "$rc"
}


trap on_error ERR


# ------------------------------------------------------------
# Atomic copy helper.
#
# File is first created beside the production target and then
# renamed into place on the same filesystem.
# ------------------------------------------------------------

atomic_install() {

    local source="$1"
    local target="$2"
    local metadata_source="$3"

    local uid
    local gid
    local mode
    local temporary

    uid="$(stat -c '%u' "$metadata_source")"
    gid="$(stat -c '%g' "$metadata_source")"
    mode="$(stat -c '%a' "$metadata_source")"

    temporary="${target}.cape-inetsim-new.$$"

    install \
        -o "$uid" \
        -g "$gid" \
        -m "$mode" \
        "$source" \
        "$temporary"

    mv -f \
        "$temporary" \
        "$target"

    echo "[INSTALLED] ${target#$CAPE_ROOT/}"
}


# ============================================================
# COMMON PREFLIGHT
# ============================================================

echo
echo "============================================================"
echo " CAPE UBUNTU-VM INETSIM PRODUCTION INSTALLER"
echo "============================================================"

echo
echo "Mode: $MODE"

# CAPE_INETSIM_EARLY_ROOT_GATE_V2
#
# A real installation must never continue through the installer
# as an unprivileged login account.
if [[ "$MODE" == "--install" && "$EUID" -ne 0 ]]; then

    fail "Real installation requires root privileges."

    echo
    echo "Run:"
    echo "  sudo $EXT_ROOT/install.sh --install"
    echo
    echo "No production CAPE file was modified."

    trap - ERR
    exit 1

fi

echo
echo "1. Read-only environment verification"

# CAPE_INETSIM_PREFLIGHT_CAPTURE_V2
#
# Capture output directly instead of reusing a predictable file
# in /tmp. This prevents sticky-directory/protected_regular
# ownership conflicts when preflight was previously run by a
# different account.
VERIFY_OUTPUT=""

if VERIFY_OUTPUT="$(
    "$EXT_ROOT/scripts/verify.sh" 2>&1
)"; then

    pass "Extension environment verifier passed"

else

    printf '%s\n' "$VERIFY_OUTPUT"

    fail "Environment verification failed"
    exit 1

fi


echo
echo "2. Production backup planning"

BACKUP_PLAN_OUTPUT=""

if BACKUP_PLAN_OUTPUT="$(
    "$EXT_ROOT/scripts/backup.sh" --dry-run 2>&1
)"; then

    pass "Production backup dry-run passed"

else

    printf '%s\n' "$BACKUP_PLAN_OUTPUT"

    fail "Backup dry-run failed"
    exit 1

fi


echo
echo "3. CAPE runtime discovery"

discover_cape_runtime


echo
echo "4. Build current-source installation candidate"

build_candidate


echo
echo "5. Candidate syntax validation"

compile_candidate


echo
echo "6. CAPE Django runtime gate"

runtime_gate


# ============================================================
# PREFLIGHT MODE STOPS HERE
# ============================================================

if [[ "$MODE" == "--preflight" ]]; then

    echo
    echo "============================================================"
    echo " INSTALLATION PREFLIGHT RESULT"
    echo "============================================================"

    echo
    echo "STATUS: PRODUCTION INSTALLATION PREFLIGHT PASSED"
    echo "No production CAPE file was modified."
    echo "Real installation was NOT performed."

    trap - ERR
    exit 0

fi


if [[ "$MODE" != "--install" ]]; then

    fail "Unknown mode: $MODE"

    echo
    echo "Usage:"
    echo "  $0 --preflight"
    echo "  sudo $0 --install"

    trap - ERR
    exit 2

fi


# ============================================================
# REAL INSTALLATION
# ============================================================

if [[ "$EUID" -ne 0 ]]; then

    fail "Real installation requires root privileges."

    echo
    echo "Run:"
    echo "  sudo $EXT_ROOT/install.sh --install"

    trap - ERR
    exit 1

fi


echo
echo "7. Create fresh automatic rollback point"

"$EXT_ROOT/scripts/backup.sh"

AUTO_BACKUP="$(
    cat "$EXT_ROOT/.last_backup"
)"

if [[ ! -d "$AUTO_BACKUP" ]]; then
    fail "Fresh backup directory was not created"
    exit 1
fi

pass "Fresh backup created: $AUTO_BACKUP"


echo
echo "8. Verify fresh rollback point"

"$EXT_ROOT/scripts/rollback.sh" --check "$AUTO_BACKUP"

pass "Fresh backup and rollback plan verified"


# Rebuild candidate AFTER the backup so it is guaranteed to
# originate from the exact source state protected above.

echo
echo "9. Rebuild candidate from protected production state"

build_candidate
compile_candidate
runtime_gate


echo
echo "10. Stop CAPE web service before atomic installation"

systemctl stop "$CAPE_WEB_SERVICE"

INSTALL_STARTED=1

pass "CAPE web service stopped"


echo
echo "11. Install validated candidate"

VIEWS_TARGET="$CAPE_ROOT/web/analysis/views.py"
NETWORK_TARGET="$CAPE_ROOT/web/templates/analysis/network/index.html"
ANALYSIS_TAGS_TEMPLATE="$CAPE_ROOT/web/analysis/templatetags/analysis_tags.py"

TAGS_TARGET="$CAPE_ROOT/web/analysis/templatetags/inetsim_vm_tags.py"
VISUAL_TARGET="$CAPE_ROOT/web/templates/analysis/network/_inetsim_vm_visual.html"
HELPER_TARGET="$CAPE_ROOT/web/analysis/inetsim_vm_logic.py"


# Helper is new on a normal installation.
# Use views.py metadata as the ownership/mode template.

atomic_install \
    "$CANDIDATE/web/analysis/inetsim_vm_logic.py" \
    "$HELPER_TARGET" \
    "$VIEWS_TARGET"


atomic_install \
    "$CANDIDATE/web/analysis/templatetags/inetsim_vm_tags.py" \
    "$TAGS_TARGET" \
    "$ANALYSIS_TAGS_TEMPLATE"


atomic_install \
    "$CANDIDATE/web/templates/analysis/network/_inetsim_vm_visual.html" \
    "$VISUAL_TARGET" \
    "$NETWORK_TARGET"


# Install the network template last because it activates the additive
# task-local INetSim tab. No CAPE view/controller code is modified.

atomic_install \
    "$CANDIDATE/web/templates/analysis/network/index.html" \
    "$NETWORK_TARGET" \
    "$NETWORK_TARGET"


echo
echo "12. Validate installed Python"

"$CAPE_PYTHON" -m py_compile \
    "$HELPER_TARGET" \
    "$TAGS_TARGET"

pass "Installed Python files compile"


echo
echo "13. Start CAPE web service"

systemctl start "$CAPE_WEB_SERVICE"


ACTIVE=0

for _ in $(seq 1 15); do

    if systemctl is-active \
        --quiet \
        "$CAPE_WEB_SERVICE"; then

        ACTIVE=1
        break

    fi

    sleep 1

done


if [[ "$ACTIVE" -ne 1 ]]; then

    systemctl status \
        "$CAPE_WEB_SERVICE" \
        --no-pager \
        -l \
        || true

    fail "CAPE web service did not become active"
    false

fi


pass "CAPE web service is active"


echo
echo "14. Verify installed extension markers"

grep -q \
    'CAPE_INETSIM_VM_ROUTE_GATED_V2' \
    "$NETWORK_TARGET"

grep -q \
    'CAPE_INETSIM_VM_MODERN_NETWORK_V1' \
    "$NETWORK_TARGET"

grep -q \
    'CAPE_INETSIM_VM_DYNAMIC_SERVER_V2' \
    "$TAGS_TARGET"

test -f "$HELPER_TARGET"
test -f "$VISUAL_TARGET"

pass "Installed modern task-network INetSim extension markers verified"


echo
echo "15. Preserve installation rollback reference"

printf '%s\n' "$AUTO_BACKUP" \
    > "$EXT_ROOT/.installed_backup"

INSTALL_STARTED=0

trap - ERR


echo
echo "============================================================"
echo " PRODUCTION INSTALLATION RESULT"
echo "============================================================"

echo
echo "STATUS: CAPE UBUNTU-VM INETSIM EXTENSION INSTALLED"
echo "Rollback backup:"
echo "  $AUTO_BACKUP"
echo
echo "CAPE web service:"
echo "  active"

exit 0

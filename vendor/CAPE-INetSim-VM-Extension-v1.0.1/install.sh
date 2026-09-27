#!/usr/bin/env bash

# ============================================================
# CAPE Ubuntu-VM INetSim Extension
# Beginner-facing installer
# ============================================================
#
# Public commands:
#
#   ./install.sh --init-config
#   ./install.sh --dry-run
#   sudo ./install.sh --install
#
# The real installation logic is implemented by:
#
#   scripts/install_production.sh
#
# ============================================================

set -Eeuo pipefail


SCRIPT_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &&
    pwd
)"

EXT_ROOT="$SCRIPT_DIR"

ENGINE="$EXT_ROOT/scripts/install_production.sh"

CONFIG="$EXT_ROOT/src/inetsim-vm.conf"

CONFIG_EXAMPLE="$EXT_ROOT/src/inetsim-vm.conf.example"

MODE="${1:---help}"


usage() {

    cat <<EOF_USAGE

CAPE Ubuntu-VM INetSim Extension

Usage:

  ./install.sh --init-config
      Create your local configuration from the universal example.

  ./install.sh --dry-run
      Perform all installation compatibility checks.
      CAPEv2 is NOT modified.

  sudo ./install.sh --install
      Create a fresh rollback backup, validate the installation
      candidate, and install the extension into CAPEv2.

  ./install.sh --help
      Show this help.

Recommended order:

  1. ./install.sh --init-config
  2. Edit src/inetsim-vm.conf for YOUR environment
  3. ./install.sh --dry-run
  4. sudo ./install.sh --install

EOF_USAGE

}


require_engine() {

    if [[ ! -x "$ENGINE" ]]; then

        echo "[FAIL] Production installation engine is missing:"
        echo "       $ENGINE"

        exit 1

    fi

}


require_config() {

    if [[ ! -r "$CONFIG" ]]; then

        echo
        echo "[FAIL] Local configuration has not been created."
        echo
        echo "Run:"
        echo
        echo "  ./install.sh --init-config"
        echo
        echo "Then edit:"
        echo
        echo "  src/inetsim-vm.conf"
        echo
        echo "The setup document explains how to determine"
        echo "every required value."

        exit 2

    fi

}


case "$MODE" in


    --init-config)

        if [[ -e "$CONFIG" ]]; then

            echo
            echo "[INFO] Local configuration already exists:"
            echo "       $CONFIG"
            echo
            echo "It was NOT overwritten."

            exit 0

        fi


        if [[ ! -r "$CONFIG_EXAMPLE" ]]; then

            echo
            echo "[FAIL] Universal configuration example is missing:"
            echo "       $CONFIG_EXAMPLE"

            exit 1

        fi


        cp \
            "$CONFIG_EXAMPLE" \
            "$CONFIG"


        echo
        echo "============================================================"
        echo " LOCAL CONFIGURATION CREATED"
        echo "============================================================"
        echo
        echo "File:"
        echo "  $CONFIG"
        echo
        echo "IMPORTANT:"
        echo "  The values currently inside are examples."
        echo "  Replace CHANGE_ME and all example network addresses"
        echo "  with values from YOUR CAPE/VM environment."
        echo
        echo "After configuration, run:"
        echo
        echo "  ./install.sh --dry-run"

        ;;


    --dry-run|--preflight)

        require_engine
        require_config

        echo
        echo "============================================================"
        echo " CAPE UBUNTU-VM INETSIM INSTALLER - DRY RUN"
        echo "============================================================"
        echo
        echo "This mode performs validation only."
        echo "No CAPEv2 production file will be modified."
        echo

        exec \
            "$ENGINE" \
            --preflight

        ;;


    --install)

        require_engine
        require_config

        exec \
            "$ENGINE" \
            --install

        ;;


    --help|-h)

        usage
        ;;


    *)

        echo
        echo "[FAIL] Unknown option: $MODE"

        usage

        exit 2
        ;;

esac

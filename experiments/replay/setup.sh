#!/bin/bash
# Reimage + reboot lg/filter, then run setup-host.sh on both. Use rerun.sh afterwards.
# Usage: setup.sh [switch lg filter]
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

if test "$#" -ne 3 -a "$#" -ne 0; then
    echo "Usage: setup.sh switch lg filter"
    exit
fi

LG_HOST="${2:-pikachu}"
FILTER_HOST="${3:-bulbasaur}"

ab_run setup "$SCRIPT_DIR" "$LG_HOST" "$FILTER_HOST"

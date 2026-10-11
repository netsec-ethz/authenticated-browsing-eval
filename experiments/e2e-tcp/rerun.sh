#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

if test "$#" -ne 4 -a "$#" -ne 0; then
    echo "Usage: rerun.sh lg filter server"
    echo "  defaults: lg=bulbasaur filter=pikachu server=snorlax"
    exit
fi

LG_HOST="${2:-bulbasaur}"
FILTER_HOST="${3:-pikachu}"
SERVER_HOST="${4:-snorlax}"

ab_run_e2e rerun "$SCRIPT_DIR" "$LG_HOST" "$FILTER_HOST" "$SERVER_HOST"

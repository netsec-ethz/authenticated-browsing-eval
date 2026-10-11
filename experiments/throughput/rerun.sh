#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

if test "$#" -ne 3 -a "$#" -ne 0; then
	echo "Usage: rerun.sh switch lg filter"
	exit
fi


LG_HOST="${2:-pikachu}"
FILTER_HOST="${3:-bulbasaur}"

ab_run rerun "$SCRIPT_DIR" "$LG_HOST" "$FILTER_HOST"

bash "$SCRIPT_DIR/collect.sh" "$LG_HOST" "$FILTER_HOST"
python3 "$SCRIPT_DIR/plot-throughput.py"

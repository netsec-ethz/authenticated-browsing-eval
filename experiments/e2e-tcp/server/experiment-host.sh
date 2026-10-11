#!/bin/bash

# Runs on the HTTP server (snorlax). Nothing to do per iteration except join the syncs.

set -e
set -x

source /root/code/pos-variables.sh

MODE=$(get_parameter mode)

# fresh nginx each iteration
systemctl restart nginx

# sync 1: start
pos_sync_robust
# sync 2: filter and lg ready
pos_sync_robust
# sync 3: lg done.
pos_sync_robust

echo "server mode=$MODE done"

#!/bin/bash
# Like run_ab.sh but with a fixed lcore list (reproducible latency) and -b <bridge>
# so port 1 <-> port 0 forwards the HTTP wire. RAW_FORWARD comes from the env.

set -euo pipefail

LCORES="${1:?missing lcores (e.g. 0-16,18-34)}"
shift
BRIDGE="${1:?missing bridge spec (e.g. 1=0)}"
shift

(( $# >= 1 )) || { echo "missing interface addresses" >&2; exit 1; }

IF_ARGS=()
for addr in "$@"; do
    IF_ARGS+=(-a "$addr")
done

exec /root/AuthBrowsing-dpdk/validator/dpdk_forward \
    -l "$LCORES" \
    "${IF_ARGS[@]}" \
    -- \
    -c /root/AuthBrowsing-dpdk/validator/config/mac.conf \
    -k /root/AuthBrowsing-dpdk/validator/config/keys.json \
    -b "$BRIDGE"

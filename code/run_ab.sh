#!/bin/bash

set -euo pipefail

CORE_COUNT="${1:?missing core count}"
shift

(( $# >= 1 )) || { echo "missing interface addresses" >&2; exit 1; }

# Sort BDFs by NUMA node so port IDs (and the round-robin workers) stay local to their NIC
mapfile -t SORTED_BDFS < <(
    for addr in "$@"; do
        node=$(cat "/sys/bus/pci/devices/${addr}/numa_node" 2>/dev/null || echo 0)
        printf '%s\t%s\n' "$node" "$addr"
    done | sort -k1,1n -k2,2 | cut -f2
)

IF_ARGS=()
for addr in "${SORTED_BDFS[@]}"; do
    IF_ARGS+=(-a "$addr")
done

# Split cores evenly over both sockets, flat 0-N on single-socket machines
SOCKET1_FIRST=$(grep -rl "^1$" /sys/devices/system/cpu/cpu[0-9]*/topology/physical_package_id \
    2>/dev/null | sed 's|.*/cpu||;s|/.*||' | sort -n | head -1)

if [[ -n "$SOCKET1_FIRST" ]]; then
    HALF=$(( CORE_COUNT / 2 ))
    SOCK0_END=$HALF
    SOCK1_END=$(( SOCKET1_FIRST + CORE_COUNT - HALF - 1 ))
    LCORES="0-${SOCK0_END},${SOCKET1_FIRST}-${SOCK1_END}"
else
    LCORES="0-${CORE_COUNT}"
fi

exec /root/AuthBrowsing-dpdk/validator/dpdk_forward \
    -l "$LCORES" \
    "${IF_ARGS[@]}" \
    -- \
    -c /root/AuthBrowsing-dpdk/validator/config/mac.conf \
    -k /root/AuthBrowsing-dpdk/validator/config/keys.json

#!/bin/bash
# Runs on the lg host (pikachu), once per loop iteration (packet_size, replay_pct).
# rate/duration/threads/flows come from global-variables.yml.

set -e
set -x

source /root/code/pos-variables.sh

DURATION=$(pos_get_variable duration --from-global)
MOONGEN_INTFS=$(pos_get_variable moongen-intfs | tr ',' ' ')

# leaked hugepages from a killed run make MoonGen fail silently
rm -f /dev/hugepages/rtemap_* 2>/dev/null || true

PACKET_SIZE=$(get_parameter packet_size)
REPLAY_PCT=$(get_parameter replay_pct)
LEGIT_PCT=$((100 - REPLAY_PCT))

# 0/100 aren't in the sweep, handled anyway
if [[ "$REPLAY_PCT" == "100" ]]; then
    MIX="legit=1,replay=99"
elif [[ "$REPLAY_PCT" == "0" ]]; then
    MIX="legit=100"
else
    MIX="legit=${LEGIT_PCT},replay=${REPLAY_PCT}"
fi

echo "[replay] iter pz=$PACKET_SIZE replay_pct=$REPLAY_PCT mix=$MIX"

# wait for experiment to start
pos_sync
# wait for filter to start
pos_sync

pos_run --loop pktgen -- /root/moongen/build/MoonGen \
    /root/AuthBrowsing-dpdk/loadgen/abgen.lua $MOONGEN_INTFS \
    -r $(get_parameter rate) -s "$PACKET_SIZE" \
    -t $(get_parameter threads) -f $(get_parameter flows) \
    --mix "$MIX" --malformed-kind random
sleep "$DURATION"
# --force-upload overwrites uploads from a previous sweep on this allocation
pos_kill --loop --force-upload pktgen

# signal to others that lg stopped
pos_sync

echo "experiment iteration done"

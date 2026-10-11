#!/bin/bash
# Runs on the experiment host, once per loop iteration.

set -e
set -x

source /root/code/pos-variables.sh

DURATION=$(pos_get_variable duration --from-global)
MOONGEN_INTFS=$(pos_get_variable moongen-intfs | tr ',' ' ')

# Leaked hugepages make MoonGen fail silently before it prints anything.
rm -f /dev/hugepages/rtemap_* 2>/dev/null || true

echo "running pktgen for $DURATION."

# wait for experiment to start
pos_sync

# wait for filter to start
pos_sync

# then start pktgen for DURATION
pos_run --loop pktgen -- /root/moongen/build/MoonGen /root/AuthBrowsing-dpdk/loadgen/abgen.lua $MOONGEN_INTFS -r $(get_parameter rate) -s $(get_parameter packet_size) -t $(get_parameter threads) -f $(get_parameter flows)
sleep "$DURATION"
# pos_kill uploads stdout; --force-upload so reruns on the same allocation don't 400
pos_kill --loop --force-upload pktgen

# signal to others that lg stopped
pos_sync

echo "experiment successful"

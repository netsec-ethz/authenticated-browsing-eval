#!/bin/bash

# Runs on the loadgen host (bulbasaur), once per loop iteration.

# exit on error
set -e
# log every command
set -x

source /root/code/pos-variables.sh

DURATION=$(pos_get_variable duration --from-global)
RATE=$(pos_get_variable rate --from-global)
ITERS=$(pos_get_variable iters --from-global)
WRK_THREADS=$(pos_get_variable wrk_threads --from-global)
WRK_CONNS=$(pos_get_variable wrk_connections --from-global)
HTTP_PATH=$(pos_get_variable http_path --from-global)

ATTACK_RATE=$(pos_get_variable attack_rate --from-global)
# get_parameter checks loop vars before globals
PACKET_SIZE=$(get_parameter packet_size)
THREADS=$(pos_get_variable threads --from-global)
FLOWS=$(pos_get_variable flows --from-global)
PLAIN_FWD_QUEUES=$(pos_get_variable plain_fwd_queues --from-global)
HTTP_OUT_MPPS=$(pos_get_variable http_out_mpps --from-global)

ATTACK_DEVS=$(pos_get_variable moongen-attack-devs)
HTTP_OUT=$(pos_get_variable moongen-http-out)
HTTP_IN=$(pos_get_variable moongen-http-in)

SNORLAX_V6=$(pos_get_variable snorlax_v6 --from-global)
SNORLAX_MAC=$(pos_get_variable snorlax_mac --from-global)
WRKOUT_V6=$(pos_get_variable wrkout_v6 --from-global)
WRKOUT_MAC=$(pos_get_variable wrkout_mac --from-global)

MODE=$(get_parameter mode)

# only the attack mode gets attack devs and args; the others just forward HTTP
LG_ENV=()
LG_POS=()
LG_ATTACK_ARGS=()
case "$MODE" in
    raw_no_attack)
        LG_ENV=("RAW_FWD=1")
        ;;
    validate_no_attack)
        ;;
    validate_with_attack)
        # ATTACK_DEVS is space-separated, split on purpose
        # shellcheck disable=SC2206
        LG_POS=( $ATTACK_DEVS )
        LG_ATTACK_ARGS=(-r "$ATTACK_RATE" -s "$PACKET_SIZE" -t "$THREADS" -f "$FLOWS" --mix forged=100 --http-out-mpps "$HTTP_OUT_MPPS")
        ;;
    *) echo "unknown mode: $MODE" >&2; exit 1 ;;
esac

echo "lg mode=$MODE env='${LG_ENV[*]}' pos='${LG_POS[*]}' attack='${LG_ATTACK_ARGS[*]}'"

# sync 1: start
pos_sync_robust

# A stale wrkout TAP or leaked hugepages from the last iteration make MoonGen fail to start.
pkill -9 MoonGen 2>/dev/null || true
ip link del wrkout 2>/dev/null || true
rm -f /dev/hugepages/rtemap_*

# abgen.lua creates the wrkout TAP once DPDK init is done
cd /root/AuthBrowsing-dpdk/loadgen
pos_run --loop pktgen --force-upload -- \
    env "${LG_ENV[@]}" \
    /root/moongen/build/MoonGen /root/AuthBrowsing-dpdk/loadgen/abgen.lua \
    "${LG_POS[@]}" \
    "${LG_ATTACK_ARGS[@]}" \
    --http-in "$HTTP_IN" --http-out "$HTTP_OUT" \
    --plain-fwd-queues "$PLAIN_FWD_QUEUES"

# TAP can take 60+ s to show up with 4 NICs + RSS
for _ in $(seq 1 90); do
    ip link show wrkout >/dev/null 2>&1 && break
    sleep 1
done
if ! ip link show wrkout >/dev/null 2>&1; then
    echo "[FAIL] wrkout TAP never appeared after 90 s for mode=$MODE" >&2
    pos_kill --loop --force-upload pktgen || true
    exit 1
fi
sleep 4

ip link set wrkout address "$WRKOUT_MAC"
ip -6 addr add "$WRKOUT_V6/64" dev wrkout nodad 2>/dev/null || true
ip link set wrkout up
ethtool -K wrkout tx off rx off tso off gso off gro off >/dev/null 2>&1 || true
ip -6 route add "$SNORLAX_V6/128" dev wrkout 2>/dev/null || true
# static neighbor, NDP across the validator bridge isn't reliable
ip -6 neigh replace "$SNORLAX_V6" lladdr "$SNORLAX_MAC" dev wrkout nud permanent
sleep 3

# HTTP smoke test. First requests can fail while everything warms up, so retry for ~90 s.
# set +e since a failing curl in SMOKE=$(...) would kill the script.
set +e
SMOKE=""
for i in $(seq 1 30); do
    SMOKE=$(curl -6 -m 4 -s -o /dev/null -w '%{http_code}' "http://[$SNORLAX_V6]$HTTP_PATH")
    [ "$SMOKE" = "200" ] && break
    sleep 3
done
set -e
if [ "$SMOKE" != "200" ]; then
    echo "[FAIL] HTTP smoke returned '$SMOKE' for mode=$MODE" >&2
    pos_kill --loop --force-upload pktgen || true
    exit 1
fi
echo "HTTP smoke ok ($SMOKE) for mode=$MODE"

# sync 2: lg and filter ready
pos_sync_robust

# mode + pkt size in the name, otherwise --force-upload overwrites earlier results
for i in $(seq 1 "$ITERS"); do
    pos_run --upload --blocking --force-upload "wrk2_${MODE}_pkt${PACKET_SIZE}_rep${i}" -- \
        /tmp/wrk2/wrk -t"$WRK_THREADS" -c"$WRK_CONNS" -d "${DURATION}s" \
                      -R "$RATE" -L "http://[$SNORLAX_V6]$HTTP_PATH"
done

# HTTP_OUT xstats show return-path drops
pos_run --loop --blocking --upload --force-upload pktgen_tel -- \
    bash -c "printf '/ethdev/xstats,${HTTP_OUT}\n/ethdev/stats,${HTTP_OUT}\n/ethdev/stats,${HTTP_IN}\n' \
             | python3 /root/MoonGen/libmoon/deps/dpdk/usertools/dpdk-telemetry.py"

# sync 3: wrk2 done
pos_sync_robust

pos_kill --loop --force-upload pktgen
ip link del wrkout 2>/dev/null || true

echo "lg mode=$MODE done"

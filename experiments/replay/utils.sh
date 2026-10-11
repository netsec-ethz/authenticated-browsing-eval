#!/bin/bash
# ab_run setup|rerun <dir> <lg> <filter>, shared by setup.sh and rerun.sh

ab_run() {
    local mode="$1"
    local script_dir="$2"
    local lg_host="$3"
    local filter_host="$4"
    local repo_root

    repo_root="$(cd "$script_dir/../.." && pwd)"

    if [[ "$mode" == "setup" ]]; then
        echo "free host"
        pos allocations free -k "$lg_host"
        pos allocations free -k "$filter_host"

        echo "allocate host"
        pos allocations allocate "$lg_host" "$filter_host"

        echo "set images"
        pos nodes image "$lg_host" debian-bookworm
        pos nodes image "$filter_host" debian-bookworm

        echo "set bootparameters"
        pos nodes bootparameter "$lg_host" iommu=pt idle=poll transparent_hugepage=never audit=0 nmi_watchdog=0 nohz=on nosoftlockup mce=ignore_ce cpuidle.off=1 skew_tick=1 processor.max_cstate=0 isolcpus=1-63 rcunocbs=1-63 rcu_nocb_poll nohz_full=1-63 irqaffinity=0 tsc=reliable random.trust_cpu=on console=tty0 console=ttyS0,115200
        pos nodes bootparameter "$filter_host" iommu=pt

        echo "load variables files"
        pos allocations set_variables "$lg_host" "$script_dir/lg/host-variables.yml"
        pos allocations set_variables "$filter_host" "$script_dir/filter/host-variables.yml"
        pos allocations set_variables "$lg_host" "$script_dir/global-variables.yml" --as-global
        pos allocations set_variables "$filter_host" "$script_dir/global-variables.yml" --as-global
        pos allocations set_variables "$lg_host" "$script_dir/loop-variables.yml" --as-loop
        pos allocations set_variables "$filter_host" "$script_dir/loop-variables.yml" --as-loop

        echo "reboot experiment hosts..."
        { pos nodes reset "$lg_host"; echo "-> $lg_host booted successfully"; } &
        { pos nodes reset "$filter_host"; echo "-> $filter_host booted successfully"; } &
        wait
    else
        cleanup_host() {
            local host="$1"
            echo "cleanup $host"
            pos commands list | awk -v node="$host" '$2 == node && ($4 == "running" || $4 == "pending" || $4 == "error") { print $1 }' | while read -r cmd_id; do
                [ -n "$cmd_id" ] || continue
                pos commands abort "$cmd_id" >/dev/null 2>&1 || true
            done
            pos commands flush "$host" >/dev/null 2>&1 || true
            ssh "$host" 'pkill -f "[/]root/moongen/build/MoonGen" >/dev/null 2>&1 || true; pkill -f "[/]root/AuthBrowsing-dpdk/validator/dpdk_forward" >/dev/null 2>&1 || true;' >/dev/null 2>&1 || true
        }
        cleanup_host "$lg_host"
        cleanup_host "$filter_host"

        # pos merges loop variables into old ones (no way to clear them), which
        # multiplies the iteration count. Re-allocating resets them; DPDK bindings survive.
        echo "free + re-allocate hosts (clears stale loop variables)"
        pos allocations free -k "$lg_host"
        pos allocations free -k "$filter_host"
        pos allocations allocate "$lg_host" "$filter_host"
    fi

    if [[ "$mode" != "setup" ]]; then
        echo "load variables files"
        pos allocations set_variables "$lg_host" "$script_dir/lg/host-variables.yml"
        pos allocations set_variables "$filter_host" "$script_dir/filter/host-variables.yml"
        pos allocations set_variables "$lg_host" "$script_dir/global-variables.yml" --as-global
        pos allocations set_variables "$filter_host" "$script_dir/global-variables.yml" --as-global
        pos allocations set_variables "$lg_host" "$script_dir/loop-variables.yml" --as-loop
        pos allocations set_variables "$filter_host" "$script_dir/loop-variables.yml" --as-loop

        pos no bootstrap "$lg_host"
        pos no bootstrap "$filter_host"
    fi

    # pos nodes copy puts <src> at /root/<basename>, so stage it as "code"
    local stage_root stage
    stage_root="$script_dir/.replay-stage"
    stage="$stage_root/code"
    rm -rf "$stage_root"
    mkdir -p "$stage_root"
    cp -r "$repo_root/code" "$stage"

    echo "upload code"
    pos nodes copy -r "$filter_host" "$stage"
    pos nodes copy -r "$lg_host"     "$stage"

    rm -rf "$stage_root"

    echo "setup experiment hosts..."
    pos commands launch --infile "$script_dir/lg/setup-host.sh"     --blocking "$lg_host"     && echo "-> $lg_host setup successfully"     || { echo "FAIL: $lg_host setup-host.sh exited non-zero" >&2; exit 1; } &
    PID_LG=$!
    pos commands launch --infile "$script_dir/filter/setup-host.sh" --blocking "$filter_host" && echo "-> $filter_host setup successfully" || { echo "FAIL: $filter_host setup-host.sh exited non-zero" >&2; exit 1; } &
    PID_FILTER=$!
    wait "$PID_LG"     || { echo "ABORT: $lg_host setup failed" >&2; exit 1; }
    wait "$PID_FILTER" || { echo "ABORT: $filter_host setup failed" >&2; exit 1; }

    echo "setup completed"

    # pos commands launch can return 0 even if the script aborted, so check the builds over ssh
    if ! ssh "$lg_host" 'test -f /root/AuthBrowsing-dpdk/loadgen/build/libabgen.so'; then
        echo "FATAL: $lg_host libabgen.so missing, cmake build failed" >&2
        exit 3
    fi
    if ! ssh "$filter_host" 'test -x /root/AuthBrowsing-dpdk/validator/dpdk_forward && readelf -p .rodata /root/AuthBrowsing-dpdk/validator/dpdk_forward 2>/dev/null | grep -q "/ab/stats"'; then
        echo "FATAL: $filter_host dpdk_forward not built with PER_CLASS_STATS=1" >&2
        exit 3
    fi
    echo "setup verified: libabgen built, validator has PER_CLASS_STATS"

    if [[ "$mode" != "setup" ]]; then
        echo "run experiments (loop over packet_size x replay_pct)..."
        pos commands launch --loop --infile "$script_dir/lg/experiment-host.sh"     --blocking "$lg_host"     && echo "-> $lg_host experiments done"     || { echo "FAIL: $lg_host experiment-host.sh exited non-zero" >&2; exit 1; } &
        PID_LG=$!
        pos commands launch --loop --infile "$script_dir/filter/experiment-host.sh" --blocking "$filter_host" && echo "-> $filter_host experiments done" || { echo "FAIL: $filter_host experiment-host.sh exited non-zero" >&2; exit 1; } &
        PID_FILTER=$!
        wait "$PID_LG"     || { echo "ABORT: $lg_host run failed" >&2; exit 1; }
        wait "$PID_FILTER" || { echo "ABORT: $filter_host run failed" >&2; exit 1; }
    fi
    echo "experiment completed"
}

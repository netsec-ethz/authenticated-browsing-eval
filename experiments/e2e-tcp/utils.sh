#!/bin/bash

# Like throughput/utils.sh, plus a third host (server, snorlax) next to lg and filter.

ab_run_e2e() {
    local mode="$1"
    local script_dir="$2"
    local lg_host="$3"
    local filter_host="$4"
    local server_host="$5"
    local repo_root

    repo_root="$(cd "$script_dir/../.." && pwd)"

    if [[ "$mode" == "setup" ]]; then
        echo "free hosts"
        pos allocations free -k "$lg_host"
        pos allocations free -k "$filter_host"
        pos allocations free -k "$server_host"

        echo "allocate hosts"
        pos allocations allocate "$lg_host" "$filter_host" "$server_host"

        echo "set images"
        pos nodes image "$lg_host" debian-bookworm
        pos nodes image "$filter_host" debian-bookworm
        pos nodes image "$server_host" debian-bookworm

        echo "set bootparameters"
        # server runs nginx on the kernel stack, so no core isolation there
        pos nodes bootparameter "$lg_host" iommu=pt idle=poll transparent_hugepage=never audit=0 nmi_watchdog=0 nohz=on nosoftlockup mce=ignore_ce cpuidle.off=1 skew_tick=1 processor.max_cstate=0 isolcpus=1-63 rcunocbs=1-63 rcu_nocb_poll nohz_full=1-63 irqaffinity=0 tsc=reliable random.trust_cpu=on console=tty0 console=ttyS0,115200
        pos nodes bootparameter "$filter_host" iommu=pt idle=poll transparent_hugepage=never audit=0 nmi_watchdog=0 nohz=on nosoftlockup mce=ignore_ce cpuidle.off=1 skew_tick=1 processor.max_cstate=0 isolcpus=1-63 rcunocbs=1-63 rcu_nocb_poll nohz_full=1-63 irqaffinity=0 tsc=reliable random.trust_cpu=on console=tty0 console=ttyS0,115200
        pos nodes bootparameter "$server_host" iommu=pt 

        echo "load variables files"
        pos allocations set_variables "$lg_host"     "$script_dir/lg/host-variables.yml"
        pos allocations set_variables "$filter_host" "$script_dir/filter/host-variables.yml"
        pos allocations set_variables "$server_host" "$script_dir/server/host-variables.yml"
        pos allocations set_variables "$lg_host"     "$script_dir/global-variables.yml" --as-global
        pos allocations set_variables "$filter_host" "$script_dir/global-variables.yml" --as-global
        pos allocations set_variables "$server_host" "$script_dir/global-variables.yml" --as-global
        pos allocations set_variables "$lg_host"     "$script_dir/loop-variables.yml" --as-loop
        pos allocations set_variables "$filter_host" "$script_dir/loop-variables.yml" --as-loop
        pos allocations set_variables "$server_host" "$script_dir/loop-variables.yml" --as-loop

        echo "reboot experiment hosts..."
        { pos nodes reset "$lg_host"; echo "-> $lg_host booted successfully"; } &
        { pos nodes reset "$filter_host"; echo "-> $filter_host booted successfully"; } &
        { pos nodes reset "$server_host"; echo "-> $server_host booted successfully"; } &
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

            ssh "$host" 'pkill -f "[/]root/moongen/build/MoonGen" >/dev/null 2>&1 || true; pkill -f "[/]root/AuthBrowsing-dpdk/validator/dpdk_forward" >/dev/null 2>&1 || true; pkill -f "[/]tmp/wrk2/wrk" >/dev/null 2>&1 || true;' >/dev/null 2>&1 || true
        }

        cleanup_host "$lg_host"
        cleanup_host "$filter_host"
        cleanup_host "$server_host"
    fi

    if [[ "$mode" != "setup" ]]; then
        echo "load variables files"
        pos allocations set_variables "$lg_host"     "$script_dir/lg/host-variables.yml"
        pos allocations set_variables "$filter_host" "$script_dir/filter/host-variables.yml"
        pos allocations set_variables "$server_host" "$script_dir/server/host-variables.yml"
        pos allocations set_variables "$lg_host"     "$script_dir/global-variables.yml" --as-global
        pos allocations set_variables "$filter_host" "$script_dir/global-variables.yml" --as-global
        pos allocations set_variables "$server_host" "$script_dir/global-variables.yml" --as-global
        pos allocations set_variables "$lg_host"     "$script_dir/loop-variables.yml" --as-loop
        pos allocations set_variables "$filter_host" "$script_dir/loop-variables.yml" --as-loop
        pos allocations set_variables "$server_host" "$script_dir/loop-variables.yml" --as-loop

        pos no bootstrap "$lg_host"
        pos no bootstrap "$filter_host"
        pos no bootstrap "$server_host"
    fi

    echo "upload code"
    pos nodes copy -r "$filter_host" "$repo_root/code"
    pos nodes copy -r "$lg_host"     "$repo_root/code"
    pos nodes copy -r "$server_host" "$repo_root/code"

    echo "setup experiment hosts..."
    pos commands launch --infile "$script_dir/lg/setup-host.sh"     --blocking "$lg_host"     && echo "-> $lg_host setup successfully"     || { echo "FAIL: $lg_host setup-host.sh exited non-zero" >&2; exit 1; } &
    PID_LG=$!
    pos commands launch --infile "$script_dir/filter/setup-host.sh" --blocking "$filter_host" && echo "-> $filter_host setup successfully" || { echo "FAIL: $filter_host setup-host.sh exited non-zero" >&2; exit 1; } &
    PID_FILTER=$!
    pos commands launch --infile "$script_dir/server/setup-host.sh" --blocking "$server_host" && echo "-> $server_host setup successfully" || { echo "FAIL: $server_host setup-host.sh exited non-zero" >&2; exit 1; } &
    PID_SERVER=$!
    wait "$PID_LG"     || { echo "ABORT: $lg_host setup failed" >&2; exit 1; }
    wait "$PID_FILTER" || { echo "ABORT: $filter_host setup failed" >&2; exit 1; }
    wait "$PID_SERVER" || { echo "ABORT: $server_host setup failed" >&2; exit 1; }

    echo "setup completed"

    if [[ "$mode" != "setup" ]]; then
        # No --blocking: the await long-poll 502s after ~3 min, iters run ~25 min.
        launch_loop_robust() {
            local script="$1" host="$2" name="$3"
            pos commands launch --loop --infile "$script" --name "$name" -n "$host" >/dev/null \
                || { echo "FAIL: submit $name on $host returned non-zero" >&2; return 1; }
            while true; do
                local active
                active=$(pos commands list "$host" 2>/dev/null \
                    | awk -v name="$name" 'NR>2 && $1 ~ name && ($4 == "running" || $4 == "pending")' \
                    | wc -l)
                [[ "$active" -eq 0 ]] && break
                sleep 30
            done
            local errored
            errored=$(pos commands list "$host" 2>/dev/null \
                | awk -v name="$name" 'NR>2 && $1 ~ name && $4 == "error"' | wc -l)
            if [[ "$errored" -gt 0 ]]; then
                echo "FAIL: $errored loop iters of $name on $host ended in error" >&2
                return 1
            fi
            return 0
        }

        echo "run experiments (loop over mode)..."
        launch_loop_robust "$script_dir/lg/experiment-host.sh"     "$lg_host"     lg_pktgen     && echo "-> $lg_host experiments done"     || { echo "FAIL: $lg_host run failed" >&2; exit 1; } &
        PID_LG=$!
        launch_loop_robust "$script_dir/filter/experiment-host.sh" "$filter_host" filter_filter && echo "-> $filter_host experiments done" || { echo "FAIL: $filter_host run failed" >&2; exit 1; } &
        PID_FILTER=$!
        launch_loop_robust "$script_dir/server/experiment-host.sh" "$server_host" server_serve  && echo "-> $server_host experiments done" || { echo "FAIL: $server_host run failed" >&2; exit 1; } &
        PID_SERVER=$!
        wait "$PID_LG"     || { echo "ABORT: $lg_host run failed" >&2; exit 1; }
        wait "$PID_FILTER" || { echo "ABORT: $filter_host run failed" >&2; exit 1; }
        wait "$PID_SERVER" || { echo "ABORT: $server_host run failed" >&2; exit 1; }
    fi
    echo "experiment completed"
}

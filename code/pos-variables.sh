function get_parameter() {
    local VAR=0
    VAR=$(pos_get_variable --from-loop $1 2>/dev/null)

    if [ $? == 0 ]; then
        echo $VAR
        return 0
    fi

    VAR=$(pos_get_variable $1 2>/dev/null)

    if [ $? == 0 ]; then
        echo $VAR
        return 0
    fi

    VAR=$(pos_get_variable --from-global $1 2>/dev/null)

    if [ $? == 0 ]; then
        echo $VAR
        return 0
    fi

    return 1
}

# The proxy in front of pos returns 502 after ~3 min regardless of --timeout,
# so long phases (e2e-tcp wrk2 runs) need a retry loop.
function pos_sync_robust() {
    local n=0
    until pos_sync "$@"; do
        n=$((n + 1))
        echo "pos_sync_robust: attempt $n returned non-zero (probably proxy 502), retrying in 2s" >&2
        sleep 2
    done
}
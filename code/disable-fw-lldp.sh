#!/bin/bash
# Usage: disable-fw-lldp.sh <ifname|bdf,...>
# Turns off the XL710 firmware LLDP agent on kernel-bound i40e ports, its frames show up as validator rejects.
# Listed ports must end up with the flag on (else exit 1), the rest are best effort.

set -euo pipefail

IFS=',' read -ra REQUIRED <<< "${1:-}"
command -v ethtool >/dev/null || { apt-get install -y ethtool >/dev/null; }

fail=0
for d in /sys/class/net/*; do
    [[ -e "$d/device/driver" ]] || continue
    [[ "$(basename "$(readlink -f "$d/device/driver")")" == "i40e" ]] || continue
    ifname=$(basename "$d")
    bdf=$(basename "$(readlink -f "$d/device")")
    ethtool --set-priv-flags "$ifname" disable-fw-lldp on 2>/dev/null || true
    state=$(ethtool --show-priv-flags "$ifname" 2>/dev/null | awk '/disable-fw-lldp/ {print $NF}')
    required=no
    for r in "${REQUIRED[@]}"; do
        [[ "$r" == "$ifname" || "$r" == "$bdf" ]] && required=yes
    done
    echo "disable-fw-lldp $ifname ($bdf): ${state:-unsupported}$([[ $required == yes ]] && echo " [required]")"
    [[ "$required" == yes && "$state" != "on" ]] && fail=1
done
exit $fail

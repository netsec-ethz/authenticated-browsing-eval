#!/usr/bin/env bash
set -euo pipefail

DEVBind_DEFAULT="/root/dpdk-23/dependencies/dpdk-23.11/usertools/dpdk-devbind.py"

usage() {
  cat >&2 <<EOF
Usage:
  $0 -i <if1,if2,...> [-d <driver>] [-p <dpdk-devbind.py>] [--force] [--pos-store <varname>]

Notes:
  Mellanox (vendor 0x15b3) NICs are automatically bound to mlx5_core.
  Other NICs use the driver specified with -d (required for non-Mellanox NICs).

Examples:
  $0 -d igb_uio   -i ens802f1np1,ens801f1np1
  $0 -d vfio-pci  -i ens802f1np1,ens801f1np1 --pos-store if-addresses
EOF
  exit 2
}

driver=""
ifcsv=""
devbind="$DEVBind_DEFAULT"
force=0
pos_store=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--driver) driver="$2"; shift 2;;
    -i|--ifaces) ifcsv="$2"; shift 2;;
    -p|--devbind) devbind="$2"; shift 2;;
    --force) force=1; shift;;
    --pos-store) pos_store="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1" >&2; usage;;
  esac
done

[[ -n "$ifcsv" ]] || usage
[[ -x "$devbind" ]] || { echo "dpdk-devbind.py not found/executable: $devbind" >&2; exit 3; }

IFS=',' read -r -a ifs <<< "$ifcsv"

# Ifaces missing from /sys/class/net are assumed already DPDK-bound (rerun)
pending=()
bdfs=()
drivers=()
for ifname in "${ifs[@]}"; do
  ifname="${ifname//[[:space:]]/}"

  if [[ ! -e "/sys/class/net/$ifname" ]]; then
    echo "$ifname not in /sys/class/net (already DPDK-bound), skipping"
    continue
  fi

  # don't cut our own ssh link
  state="$(cat "/sys/class/net/$ifname/operstate" 2>/dev/null || true)"
  if [[ "$state" == "up" && "$force" -ne 1 ]]; then
    echo "Refusing: interface $ifname is UP (operstate=up). Use --force if you're sure." >&2
    exit 5
  fi

  bdf="$(basename "$(readlink -f "/sys/class/net/$ifname/device")")"
  # add 0000: domain if missing
  [[ "$bdf" == *:*:*.* ]] || bdf="0000:$bdf"

  vendor="$(cat "/sys/bus/pci/devices/$bdf/vendor")"
  if [[ "$vendor" == "0x15b3" ]]; then
    drv="mlx5_core"
  else
    [[ -n "$driver" ]] || { echo "No driver specified (-d) for non-Mellanox interface $ifname" >&2; exit 6; }
    drv="$driver"
  fi

  pending+=("$ifname")
  bdfs+=("$bdf")
  drivers+=("$drv")
done

# Cache BDFs on disk in case the netdevs are gone and the pos var was wiped (free + re-allocate)
CACHE_FILE="/var/lib/auth-browsing/bdfs.csv"

if [[ ${#bdfs[@]} -gt 0 ]]; then
  bdf_csv="$(IFS=','; echo "${bdfs[*]}")"
  mkdir -p "$(dirname "$CACHE_FILE")"
  echo "$bdf_csv" > "$CACHE_FILE"
fi

# Keep an existing pos var (first-run ordering), else set it from this run or the cache
if [[ -n "$pos_store" ]]; then
  if pos_get_variable "$pos_store" &>/dev/null; then
    : # already set
  elif [[ ${#bdfs[@]} -gt 0 ]]; then
    pos_set_variable "$pos_store" "$bdf_csv"
  elif [[ -s "$CACHE_FILE" ]]; then
    echo "Restoring $pos_store from cache $CACHE_FILE: $(cat "$CACHE_FILE")"
    pos_set_variable "$pos_store" "$(cat "$CACHE_FILE")"
  else
    echo "Cannot determine BDFs: all ifaces already DPDK-bound, pos var '$pos_store' unset, no cache at $CACHE_FILE. Reboot the node to recover." >&2
    exit 7
  fi
fi

if [[ ${#pending[@]} -eq 0 ]]; then
  echo "All interfaces already DPDK-bound, nothing to do."
  exit 0
fi

echo "Binding interfaces:"
for idx in "${!pending[@]}"; do
  echo "  ${pending[$idx]} -> ${bdfs[$idx]} (${drivers[$idx]})"
done

for ifname in "${pending[@]}"; do
  ip link set "$ifname" down 2>/dev/null || true
done

for idx in "${!bdfs[@]}"; do
  "$devbind" -b "${drivers[$idx]}" "${bdfs[$idx]}"
done
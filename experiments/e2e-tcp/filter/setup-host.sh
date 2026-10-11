#!/bin/bash

# Runs on the validator host (pikachu).

# exit on error
set -e
# log every command
set -x

cd /root

# disable rt throttling
echo -1 > /proc/sys/kernel/sched_rt_runtime_us

# set virt memory stats collector 3600s interval (default 1s)
sysctl vm.stat_interval=3600

# disable numa balancing
echo 0 > /proc/sys/kernel/numa_balancing

# update apt repository
apt update -y

# install ntp to sync time
apt-get update -y
apt-get install -y ntpsec ethtool
# For building
apt -y install build-essential gcc make cmake pkg-config
# OpenSSL
apt -y install libssl-dev
# AESNI
apt -y install yasm
# Testing Dependencies
apt -y install bsdmainutils tmux
apt -y install build-essential meson ninja-build python3-pyelftools libnuma-dev pkg-config libssl-dev yasm
# Mellanox mlx5 PMD requires libibverbs
apt -y install libibverbs-dev ibverbs-providers

# 16-byte i40e RX descriptors: +3% Mpps on the XL710s at 86 B.
DPDK_C_ARGS="-DRTE_LIBRTE_I40E_16BYTE_RX_DESC"
if [[ ! -d /root/dpdk-23.11 ]] || ! grep -q -- "$DPDK_C_ARGS" /root/dpdk-23.11/build/meson-info/intro-buildoptions.json 2>/dev/null; then
    curl -LO https://fast.dpdk.org/rel/dpdk-23.11.tar.xz
    echo "896c09f5b45b452bd77287994650b916 dpdk-23.11.tar.xz" | md5sum -c
    tar xJf dpdk-23.11.tar.xz

    cd dpdk-23.11
    rm -rf build
    meson setup build --prefix=/root/dpdk-23.11-inst -Dc_args="$DPDK_C_ARGS"
    ninja -C build
    ninja -C build install
    cd /root
fi
grep -q -- "$DPDK_C_ARGS" /root/dpdk-23.11/build/meson-info/intro-buildoptions.json || {
    echo "DPDK was not built with $DPDK_C_ARGS" >&2
    exit 1
}

export PKG_CONFIG_PATH="/root/dpdk-23.11-inst/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

grep -qxF 'export PKG_CONFIG_PATH="/root/dpdk-23.11-inst/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"' /root/.bashrc || \
echo 'export PKG_CONFIG_PATH="/root/dpdk-23.11-inst/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"' >> /root/.bashrc

export LD_LIBRARY_PATH="/root/dpdk-23.11-inst/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
grep -qxF 'export LD_LIBRARY_PATH="/root/dpdk-23.11-inst/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"' /root/.bashrc || \
echo 'export LD_LIBRARY_PATH="/root/dpdk-23.11-inst/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"' >> /root/.bashrc
echo '/root/dpdk-23.11-inst/lib/x86_64-linux-gnu' > /etc/ld.so.conf.d/dpdk.conf
ldconfig

AB_REPO=$(pos_get_variable git/ab/repo --from-global)
AB_REPO_COMMIT=$(pos_get_variable git/ab/commit --from-global)
cd /root
if [[ ! -d /root/AuthBrowsing-dpdk/.git ]]; then
    rm -rf /root/AuthBrowsing-dpdk
    git clone "$AB_REPO" /root/AuthBrowsing-dpdk
else
    git -C /root/AuthBrowsing-dpdk remote set-url origin "$AB_REPO"
    git -C /root/AuthBrowsing-dpdk fetch --all --tags
fi
cd /root/AuthBrowsing-dpdk
# untracked leftovers from an older checkout would block the checkout
git stash --include-untracked >/dev/null 2>&1 || true
git checkout "$AB_REPO_COMMIT"
cd /root/AuthBrowsing-dpdk/validator
make clean
make
# bail out if the PMAC1 KATs or batched PMAC test fail
./lib/aesni/test/pmac1_kat
./lib/aesni/test/pmac1_batch_test
# bridged HTTP goes to snorlax's NIC MAC (via the switch)
echo "mac=$(pos_get_variable snorlax_mac --from-global)" > config/mac.conf

git config user.name "AB"
git config user.email ab@example.com

if ! mount | grep -q hugetlbfs; then
  mkdir -p /mnt/huge
  mount -t hugetlbfs nodev /mnt/huge
fi

# setup hugepages
echo '8192' | tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# install igb_uio
if [[ ! -d /root/dpdk-kmods ]]; then
    cd /root/
    git clone https://dpdk.org/git/dpdk-kmods
fi
cd /root/dpdk-kmods/linux/igb_uio/
chrt 1 taskset -c 1-63 make
modprobe uio
insmod igb_uio.ko 2>/dev/null || true
cd /root/

# XL710 firmware sends LLDP frames that would show up as validator rejects.
/root/code/disable-fw-lldp.sh "$(pos_get_variable if-addresses)"
IF_ADDRESSES_CSV=$(pos_get_variable if-addresses)
DEVBIND=/root/dpdk-23.11/usertools/dpdk-devbind.py
IFS=',' read -ra IF_ADDRESSES <<< "$IF_ADDRESSES_CSV"
# Bind by BDF, not ifname: already-bound NICs have no ifname on a rerun.
for bdf in "${IF_ADDRESSES[@]}"; do
    "$DEVBIND" --bind=igb_uio "$bdf" || true
done

cd /root/
echo "Filter (validator) bound to igb_uio: $IF_ADDRESSES_CSV"

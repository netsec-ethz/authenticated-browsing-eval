#!/bin/bash
# Runs on the filter host (bulbasaur). Builds dpdk_forward with PER_CLASS_STATS,
# which analyze.py needs for the per-class rx/tx counters in /ab/stats.

set -e
set -x

cd /root

echo -1 > /proc/sys/kernel/sched_rt_runtime_us
sysctl vm.stat_interval=3600
echo 0 > /proc/sys/kernel/numa_balancing

apt update -y
apt-get update -y
apt-get install -y ntpsec ethtool
apt -y install build-essential gcc make cmake pkg-config
apt -y install libssl-dev
apt -y install yasm
apt -y install bsdmainutils tmux
apt -y install build-essential meson ninja-build python3-pyelftools libnuma-dev pkg-config libssl-dev yasm
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
# local edits would make the checkout fail
git reset --hard HEAD
git clean -fd
git checkout "$AB_REPO_COMMIT"
git reset --hard "$AB_REPO_COMMIT"
git clean -fd
cd /root/AuthBrowsing-dpdk/validator
make clean
make PER_CLASS_STATS=1
# PMAC1 known-answer and batch equivalence tests; abort setup if they fail
./lib/aesni/test/pmac1_kat
./lib/aesni/test/pmac1_batch_test

git config user.name "AB"
git config user.email ab@example.com

if ! mount | grep -q hugetlbfs; then
    mkdir -p /mnt/huge
    mount -t hugetlbfs nodev /mnt/huge
fi
echo '8192' | tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null

if [[ ! -d /root/dpdk-kmods ]]; then
    cd /root/
    git clone https://dpdk.org/git/dpdk-kmods
fi
cd /root/dpdk-kmods/linux/igb_uio/
chrt 1 taskset -c 1-63 make
modprobe uio
insmod igb_uio.ko 2>/dev/null || true
cd /root/

IFS=$(pos_get_variable intfs)
cd /root/code/
# XL710 firmware sends LLDP frames that would show up as validator rejects.
/root/code/disable-fw-lldp.sh "$IFS"
./bind-dpdk-ifaces.sh -d igb_uio -i "$IFS" -p /root/dpdk-23.11/usertools/dpdk-devbind.py --pos-store if-addresses

cd /root/

echo "setup successful (PER_CLASS_STATS validator built)"

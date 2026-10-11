#!/bin/bash
# Runs on the lg host (pikachu): builds MoonGen and the AB loadgen.

set -e
set -x

cd /root

apt-get update -y
apt-get install -y ntp

apt-get update
apt-get install -y \
    meson ninja-build pkg-config python3-pyelftools libsystemd-dev \
    rdma-core ibverbs-providers libibverbs-dev librdmacm-dev \
    libnl-3-dev libnl-route-3-dev

MOONGEN_REPO=$(pos_get_variable git/moongen/repo --from-global)
MOONGEN_REPO_COMMIT=$(pos_get_variable git/moongen/commit --from-global)
cd /root
if [[ ! -d /root/MoonGen/.git ]]; then
    rm -rf /root/MoonGen
    git clone "$MOONGEN_REPO" /root/MoonGen
else
    git -C /root/MoonGen fetch --all --tags
fi
ln -sfn /root/MoonGen /root/moongen
cd /root/moongen
git checkout "$MOONGEN_REPO_COMMIT"
git submodule update --init
cp -r /root/code/moongen-patches/* /root/moongen/
cd libmoon
./build.sh --noBind --moongen
cd /root/moongen
./setup-hugetlbfs.sh
# libmoon's default 1024 pages is too few for 16 threads x 4 NICs (silent segfault in device.config)
echo 8192 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

IFS=$(pos_get_variable intfs)

DPDK_DEVBIND=/root/moongen/libmoon/deps/dpdk/usertools/dpdk-devbind.py
cd /root/code/

# XL710 firmware sends LLDP frames that would show up as validator rejects.
/root/code/disable-fw-lldp.sh "$IFS"
./bind-dpdk-ifaces.sh -d igb_uio -i "$IFS" -p "$DPDK_DEVBIND"

apt-get install -y libssl-dev yasm

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

cd /root/AuthBrowsing-dpdk/loadgen
mkdir -p build
cd build
cmake ..
make -j

git config user.name "AB"
git config user.email ab@example.com

# First DPDK init after boot still makes the XL710s send 3 LLDP frames per port,
# so do a short warm-up run here instead of in the first iteration. IFS reset since we overwrote it above.
WARM_INTFS=$(pos_get_variable moongen-intfs | tr ',' ' ')
(IFS=$' \t\n'; cd /root/moongen && timeout -s INT 30 ./build/MoonGen /root/AuthBrowsing-dpdk/loadgen/abgen.lua $WARM_INTFS -r 1 -s 90 -t 1 -f 1 > /tmp/lldp-warmup.log 2>&1) || true
grep -q "Found 4 usable devices\|Device 0" /tmp/lldp-warmup.log || { echo "loadgen warm-up did not initialise the ports" >&2; cat /tmp/lldp-warmup.log >&2; exit 1; }
rm -f /dev/hugepages/rtemap_*

echo "setup successful"

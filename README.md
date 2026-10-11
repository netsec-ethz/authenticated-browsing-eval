# authenticated-browsing-eval

Evaluation artifacts for AuthBrowsing: the scripts, configs and patches we used
to benchmark the DPDK validator on our testbed. The validator itself lives in a
[separate repo](https://github.com/netsec-ethz/authenticated-browsing), alongside the load generator.

## Layout

- `code/`: wrapper scripts that launch the validator on a host (NUMA-aware lcore
  pinning, NIC binding, MoonGen patches).
- `experiments/`: one folder per experiment, each with the same layout:
  - `throughput/`: packet rate and core count sweeps against the validator.
  - `e2e-tcp/`: end-to-end HTTP latency and req/s with an HTTP server behind
  an AB validator.
  - `replay/`: how the validator handles replays mixed into legitimate traffic.
  - `triage/`: how the validator handles attack traffic (forged MACs mixed with
  legitimate ones).

Each experiment folder has a `run.sh`, a `setup.sh`, a
`global-variables.yml` pinning the upstream commits we tested against, and a
plotting script that turns `results/` into the figures.

## Running

Running the experiments is easiest on a pos testbed (or something close to it). The
experiments require, at a minimum, two DPDK-capable hosts with a NIC each.
From an experiment folder:

```sh
./setup.sh   # provisions hosts, builds AuthBrowsing-dpdk + MoonGen
./run.sh     # sweeps the loop variables, drops raw output in results/
./plot-*.py  # turns results/ into a figure
```

`rerun.sh` runs again on existing allocations without re-provisioning, so you
don't wait for reboots.

## Notes

- The MoonGen patches under `code/moongen-patches/` are needed for the rate
  control we use. Copy them on top of the pinned commit.

# AetherS3 benchmark harness

A reproducible loop for finding where AetherS3 spends its time under load, so VM
(and application) tuning is driven by data instead of guesswork.

The sequence that matters: **run a stock-args baseline first, read the msacc
attribution to learn what you're bound by, and only then change `ERL_ZFLAGS`.**
BEAM defaults are good; a flag helps only when the breakdown points at a
VM-level bottleneck.

## What it does

`run.sh` boots a fixed cluster (`compose.bench.yml`), arms per-node **microstate
accounting**, drives the cluster with [`warp`](https://github.com/minio/warp)
(MinIO's S3 load generator), then writes one results file combining:

- **warp**: throughput (obj/s, MiB/s) and per-operation latency percentiles.
- **`collect.exs`**: per-node msacc breakdown (where the schedulers spent the
  window) plus reduction / GC / IO / memory deltas.

`collect.exs` runs as a throwaway distributed node that reads raw ERTS counters
over `:erpc` — no `runtime_tools` in the image required, so it works against the
stock published release.

## Requirements

Docker only. Images are pulled on first use: the AetherS3 release, `minio/warp`,
`elixir:1.20-otp-29-alpine` (the collector), and `curlimages/curl` (readiness).

> **Substrate matters.** VM-arg tuning is specific to the OS/CPU/IO you run on.
> Results from a laptop/OrbStack VM will **not** transfer to a Linux server —
> run the harness on hardware representative of where you'll deploy.

## Usage

```sh
cd bench

# Baseline: mixed 1 MiB objects, 3 nodes, RF=3, stock VM args.
./run.sh

# Other workloads (each stresses a different subsystem):
WORKLOAD=small ./run.sh    # 8 KiB objects  -> metadata / :erpc bound
WORKLOAD=large ./run.sh    # 16 MiB objects -> streaming / disk / distribution bound
WORKLOAD=list  ./run.sh    # LIST-heavy     -> CubDB range-scan bound

# Exercise the SigV4 path (uses the seeded root creds):
AUTH=true WORKLOAD=small ./run.sh

# A tuning pass — same workload, different VM args, labelled for comparison:
ERL_ZFLAGS="+zdbbl 32768"           LABEL=zdbbl  WORKLOAD=large ./run.sh
ERL_ZFLAGS="+sbwt none +sbwtdio none" LABEL=sbwt  WORKLOAD=mixed ./run.sh
```

Each run writes `results/<timestamp>-<workload>-<label>.md`. Compare the warp
numbers across runs; use the msacc section to explain *why* they moved.

### Knobs

| Env | Default | Meaning |
|---|---|---|
| `NODES` | 3 | cluster size |
| `RF` / `WQ` | 3 / 1 | replication factor / write quorum |
| `AUTH` | false | SigV4 on/off |
| `WORKLOAD` | mixed | `small` \| `large` \| `mixed` \| `list` |
| `DURATION` | 60s | warp run length |
| `ERL_ZFLAGS` | (stock) | extra BEAM VM args, no rebuild |
| `LABEL` | baseline | tag in the results filename |
| `KEEP` | 0 | `1` leaves the cluster up |

## Reading the msacc breakdown

Per scheduler type, the busy % and how it splits across states:

- **normal `scheduler`, high `emulator`** — CPU/app-bound (S3 parsing, SigV4,
  HRW, CubDB in-process work). VM flags won't save you; optimize the code path.
- **high `check_io`** — socket/network bound (Bandit accept/read, dist).
- **busy `dirty_io_scheduler`** — disk bound (CubDB, blob files). Try `+SDio`.
- **high `gc` / large reclaimed** — allocation churn; look at binary handling.
- **`sleep` high on every type** — not saturated: add `--concurrent`, or the
  limit is latency somewhere off-CPU (quorum wait, a slow replica).

A genuine possible finding: if `large` throughput is capped and the ceiling
tracks inter-node transfer, the bottleneck may be **bulk data over BEAM
distribution** (`:erpc` blob chunks) rather than any flag — in which case the fix
is architectural (move blob bytes off distribution), and `+zdbbl` only softens it.

## Files

| File | Role |
|---|---|
| `compose.bench.yml` | fixed cluster; every run knob is an env var |
| `run.sh` | orchestrator: boot → arm → warp → collect → write results |
| `collect.exs` | `:erpc` microstate-accounting collector (observer node) |
| `results/` | one Markdown file per run (git-tracked; the raw `.state` isn't) |

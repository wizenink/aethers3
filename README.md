# AetherS3

A self-hostable, distributed, S3-compatible object store that runs on the BEAM.

AetherS3 stores objects across a cluster of nodes and speaks enough of the S3
HTTP API to be driven by standard S3 clients (bucket and object operations,
range reads, multipart uploads). It is built as an Erlang/OTP application: nodes
discover each other, replicate object data, and self-heal without an external
coordinator.

This is a learning project, not a production system. See [Status and
limitations](#status-and-limitations) before relying on it for anything.

## Design

The system splits into two planes:

- **Data plane (AP).** Object blobs and their metadata. Placement is decided by
  rendezvous (HRW) hashing: every node independently computes the same ordered
  list of replica nodes for a given `{bucket, key}`, so there is no placement
  registry to keep in sync. Writes are accepted as soon as one replica is
  durable (`W=1`); the remaining replicas are filled asynchronously and an
  anti-entropy loop repairs anything that drifts. Conflicts resolve
  last-writer-wins by modification time. Reads locate a live replica and stream
  the object back, proxying from a peer node when the local node does not hold a
  copy.
- **Control plane (CP).** Bucket existence and other metadata that must be
  globally consistent. Backed by Khepri (a Raft/`ra` tree store), so bucket
  creation and deletion go through consensus.

Blobs are stored on local disk; object metadata lives in an embedded CubDB
store; the control-plane tree lives in Khepri's Ra log. Cluster membership is
discovered by libcluster and the control plane auto-joins the Raft cluster on
startup.

## Requirements

- Elixir `~> 1.20` on Erlang/OTP 27+ (for building from source / dev).
- Docker, to run a cluster the easy way.
- `zig` (only if you want to build a single self-contained binary with Burrito).

## Running it

### Single node (development)

```sh
mix deps.get
mix run --no-halt
```

This boots one non-distributed node serving the S3 API on port 9000. Auth is on
by default with the development credentials below.

Smoke test with curl (auth disabled for brevity — set `AETHER_REQUIRE_AUTH=false`
when starting, or use a real S3 client for signed requests):

```sh
AETHER_REQUIRE_AUTH=false mix run --no-halt &

curl -X PUT http://localhost:9000/my-bucket                 # create bucket
curl -X PUT http://localhost:9000/my-bucket/hello --data 'hi'   # put object
curl http://localhost:9000/my-bucket/hello                  # get object
curl http://localhost:9000/my-bucket                        # list bucket
```

### A local multi-node cluster

Start nodes with distinct names and the same cookie on the same host. libcluster
uses LocalEpmd to discover same-host peers automatically:

```sh
AETHER_PORT=9000 AETHER_DATA_DIR=tmp/n1 \
  iex --sname aether1 --cookie aether -S mix run

AETHER_PORT=9001 AETHER_DATA_DIR=tmp/n2 \
  iex --sname aether2 --cookie aether -S mix run

AETHER_PORT=9002 AETHER_DATA_DIR=tmp/n3 \
  iex --sname aether3 --cookie aether -S mix run
```

Give each node its own `AETHER_DATA_DIR`. With three nodes up and a replication
factor of 3, every object is replicated to all of them; create a bucket on one
node and it is visible on all.

### Docker (recommended for a real cluster)

```sh
docker compose up --build --scale aether=3
```

Each container names itself `aether@<container-ip>`. Discovery uses DNSPoll: the
compose service name `aether` resolves to every container IP, and the nodes
form a Raft cluster on startup. The object API is exposed on port 9000; epmd
(4369) and the pinned distribution ports (9100–9110) stay on the internal
network.

### Single binary (Burrito)

Builds one self-contained executable per target (no Erlang/Elixir needed on the
host that runs it):

```sh
brew install zig          # or your platform's zig package
BURRITO_BUILD=1 MIX_ENV=prod mix rel
# -> burrito_out/aether_s3_macos, burrito_out/aether_s3_linux
```

Without `BURRITO_BUILD=1`, `mix rel` produces a plain OTP release folder under
`_build/prod/rel/aether_s3` (this is what the Docker image ships). Run it with:

```sh
RELEASE_NODE=aether@127.0.0.1 RELEASE_COOKIE=secret \
  _build/prod/rel/aether_s3/bin/aether_s3 start
```

## Configuration

All runtime configuration is via environment variables.

| Variable | Default | Purpose |
| --- | --- | --- |
| `AETHER_PORT` | `9000` | S3 API listen port. |
| `AETHER_DATA_DIR` | `tmp/aether_data` | Where blobs, metadata, and the Khepri log live. One per node. |
| `AETHER_REQUIRE_AUTH` | `true` | SigV4 auth on/off. |
| `AETHER_LOG_LEVEL` | `info` | Log level (`debug`, `info`, `warning`, `error`, …). Can also be changed live — see below. |
| `AETHER_ACCESS_KEY` | `AKIAEXAMPLE` | S3 access key (development default). |
| `AETHER_SECRET_KEY` | `devsecret` | S3 secret key (development default). |
| `AETHER_REPLICATION_FACTOR` | `3` | Number of replicas per object. |
| `AETHER_WRITE_QUORUM` | `1` | Replicas that must ack before a PUT returns: an integer, `quorum`, or `all`. Higher = more durable, less available. |
| `AETHER_PEERS` | _(unset)_ | Comma-separated static node list → Epmd discovery (e.g. `aether@n1,aether@n2`). |
| `AETHER_DNS_QUERY` | _(unset)_ | DNS name → DNSPoll discovery (resolve to peer IPs). |
| `AETHER_GOSSIP` | _(unset)_ | `true` → Gossip discovery (UDP multicast on the LAN; good for VMs). |
| `AETHER_GOSSIP_SECRET` | _(unset)_ | Optional shared secret encrypting gossip, so only nodes that share it join. |
| `AETHER_NODE_BASENAME` | `aether` | Node basename used to build peer node names under DNSPoll. |
| `AETHER_CP_EVICT_GRACE` | _(unset)_ | Seconds a control-plane member must be unreachable before the Raft leader evicts it. Unset = disabled (opt-in). |
| `AETHER_MPU_REAP_AGE` | _(unset)_ | Seconds after which a multipart upload with no Complete/Abort is swept (parts + marker deleted). Unset = disabled (opt-in). |
| `AETHER_STAGING_SWEEP_AGE` | `3600` | Seconds a crashed-write staging temp (`.staging`/`.tmp`) must age before it's reclaimed. Always on; raise to protect very slow in-flight writes. |
| `AETHER_CONFIG` | `/etc/aether_s3/config.toml` | Path to the production TOML config file (see below). |

Discovery precedence: `AETHER_PEERS` → `AETHER_DNS_QUERY` → `AETHER_GOSSIP` → LocalEpmd (same-host dev default).

To change the log level on a **running** node without a restart (e.g. to capture
debug output during an incident), use the release remote shell:

```
bin/aether_s3 rpc 'AetherS3.Config.set_log_level("debug")'
```

Node name and cookie are BEAM-level (set before the app boots, so they can't go
in the TOML file). Use `AETHER_NODE` / `AETHER_COOKIE` (friendly aliases), or the
underlying `RELEASE_NODE` / `RELEASE_COOKIE` (an explicit `RELEASE_*` wins). The
node name must be an IP or FQDN — see "Cluster discovery" below. `RELEASE_DISTRIBUTION`
defaults to `name`. The cookie can also be a `~/.erlang.cookie` file (mode 0400),
which is the preferred prod approach. (These aliases are wired in `rel/env.sh.eex`,
which applies on Linux and macOS; Windows would need a `rel/env.bat.eex`.)

The default credentials are for local development only. Set real ones, turn on
auth, and use a private cookie before exposing a node.

### Production config file (TOML)

Environment variables are the dev/default path. For production, drop a TOML file
at `AETHER_CONFIG` (default `/etc/aether_s3/config.toml`); when present, its
values override the environment. See `config.toml.example` for the full schema:

```toml
port = 9000
data_dir = "/var/lib/aether_s3"
replication_factor = 3
write_quorum = "quorum"
require_auth = true

[credentials]
AKIAEXAMPLE = "change-me"

[cluster]
strategy = "dns"          # "dns" | "epmd" (static list) | "gossip" (LAN multicast)
dns_query = "aether.internal"   # for "dns"
node_basename = "aether"
# peers  = ["aether@n1", "aether@n2", "aether@n3"]   # for "epmd"
# secret = "shared-gossip-secret"                      # for "gossip"
```

For Docker, mount the file in (e.g. `-v ./config.toml:/etc/aether_s3/config.toml`);
for the Burrito binary it just needs to exist at that path on the host. The node
**name** and **cookie** are BEAM-level (set via `RELEASE_NODE` /
`rel/vm.args.eex` and `RELEASE_COOKIE` / `~/.erlang.cookie`), not this file.

## Cluster discovery across machines

Discovery only decides how nodes *find* each other's names; once found, every
strategy connects over the same BEAM transport. So two things always apply:

- **Node name must be an IP or an FQDN** (contain a dot). With long-name
  distribution a bare short hostname like `aether1` is rejected
  (`Hostname ... illegal`) — use `aether@10.0.0.5` or `aether@n1.lan`.
- **Same cookie** on every node (`RELEASE_COOKIE`, or `~/.erlang.cookie`).

The strategy is chosen at runtime (env or the TOML `[cluster]` block):

| Strategy | Trigger | Best for |
| --- | --- | --- |
| LocalEpmd | _(default)_ | same-host dev |
| Epmd (static) | `AETHER_PEERS=aether@n1,aether@n2,...` | fixed, stable-name nodes |
| DNSPoll | `AETHER_DNS_QUERY=<dns-name>` | containers / k8s (headless service) |
| Gossip | `AETHER_GOSSIP=true` | VMs on one LAN (auto-discovery) |

Ports that must be open **between nodes** (on top of the per-strategy channel):
epmd **TCP 4369** and the distribution range **TCP 9100–9110** (pinned in
`rel/vm.args.eex`). Per-strategy discovery channel: DNSPoll → DNS (53); Gossip →
**UDP 45892 multicast**; Epmd/LocalEpmd → none extra. The S3 API (9000) is
client-facing and unrelated to clustering.

### Running on a LAN of VMs (e.g. Proxmox) with Gossip

Gossip auto-discovers peers via UDP multicast — no static list or DNS needed.
On each VM, run the release (or the Burrito binary) with:

```sh
AETHER_NODE=aether@<this-vm-ip> \
AETHER_COOKIE=<shared-secret> \
AETHER_GOSSIP=true \
AETHER_GOSSIP_SECRET=<shared-gossip-secret> \
AETHER_DATA_DIR=/var/lib/aether_s3 \
  bin/aether_s3 start
```

The VMs must share an L2 network so multicast reaches them (Proxmox VMs on the
same bridge/VLAN do), with UDP 45892 + TCP 4369 + 9100–9110 open between them.
If you run it as a **Docker** container on each VM, use host networking
(`network_mode: host`) — bridged Docker NAT breaks cross-host multicast and
distribution. Running the release directly on the VM avoids that.

### Process supervision (and control-plane self-healing)

Run each node under a process supervisor so it restarts on crash — Docker's
`restart:` policy, Kubernetes, or, on a bare VM, **systemd**:

```ini
# /etc/systemd/system/aether.service
[Service]
Environment=AETHER_NODE=aether@10.0.0.5
Environment=AETHER_COOKIE=shared-secret
Environment=AETHER_GOSSIP=true
ExecStart=/opt/aether/bin/aether_s3 start
Restart=on-failure
[Install]
WantedBy=multi-user.target
```

Control-plane member lifecycle does **not** depend on this, though: dead members
are evicted by the Raft leader after `AETHER_CP_EVICT_GRACE` (opt-in), and an
evicted node heals itself **at boot** — before starting Khepri it checks with a
peer and wipes its stale Raft state if it was removed, then rejoins cleanly. No
external restart is needed for that path; it only wipes the control-plane log
(blobs and object metadata are untouched and re-sync from the leader).

## Tests

Unit tests (fast, in-process):

```sh
mix test
mix format --check-formatted
mix compile --warnings-as-errors
```

End-to-end tests drive a **real S3 client** (aws-cli) against an actual cluster
and verify the cross-node guarantees (write to one node, read from another;
multipart; ranged GET; delete; list). All run in CI:

```sh
test/e2e/same_host.sh       # 3 nodes on one host (LocalEpmd); needs elixir + aws-cli
test/e2e/docker_cluster.sh  # 3 containers (DNSPoll); needs docker (uses the amazon/aws-cli image)
test/e2e/split_brain.sh     # partitions a 3-node cluster, proves recovery (see below)
test/e2e/rebalance.sh       # grows 3->5 nodes, proves migration + orphan shedding
```

`rebalance.sh` writes a batch to a 3-node cluster, adds 2 more nodes, and asserts
anti-entropy **migrates** objects to the new HRW owners *and* **sheds** them from
nodes that are no longer replicas — verified by the total copy count staying at
`objects × replication_factor` (migration alone would balloon it) while the new
nodes receive data.

`split_brain.sh` partitions the cluster (an `iptables` sidecar in each minority
node's network namespace) and asserts the two recovery behaviors: the **control
plane** (Raft) keeps quorum on the majority and the minority's bucket-create does
not reach the consistent log during the split, then the minority resyncs on heal;
and the **data plane** (AP) takes divergent writes to the same key on both sides
(W=1) and **converges to the last-writer-wins value** on heal.

It defaults to a 3-node split (majority {1,2} vs lone node {3}) but is
parameterizable for any split — e.g. a 5-node 3-vs-2 split where *both* sides are
multi-node sub-clusters:

```sh
SB_COMPOSE=docker-compose.static5.yml SB_PROJECT=aether-split5 \
SB_MAJORITY="1 2 3" SB_MINORITY="4 5" test/e2e/split_brain.sh
```

## Status and limitations

Working: replicated writes with a **configurable write quorum** (W), range-aware
reads with cross-node proxying and **read-repair**, **version-vector** conflict
resolution (LWW tiebreak for true conflicts), fan-out deletes, scatter-gather
listing, the Khepri control plane with libcluster auto-discovery + Raft auto-join,
**dead-member eviction and boot-time self-heal** of an evicted node, an
anti-entropy loop that also **rebalances** (migrates *and* sheds) on topology
change, reaping of abandoned multipart uploads, and an end-to-end test suite
(same-host, Docker, split-brain, rebalance, and reaping) that runs in CI.

Known gaps and future work:

- **Security/auth:** one hardcoded credential pair, no bucket policies/ACLs, no
  TLS, and the `__mpu__` internal bucket is client-reachable. Not safe to expose.
- **Formation-window write loss (control plane):** a Khepri `join` makes a fresh
  joiner adopt the cluster's state, so a control-plane write in the ~1 s before
  initial Raft membership stabilizes can be lost. (Steady-state partitions are
  fine — a reconnecting member *resyncs*, it doesn't re-join.)
- **Conflict resolution is single-value:** concurrent writes to the same key
  converge to one version (version vectors detect the conflict, but S3 can't
  expose siblings, so the losing write is discarded).
- **Orphan cleanup:** abandoned multipart uploads are reaped (opt-in, via
  `AETHER_MPU_REAP_AGE`), but parts orphaned when a manifest is overwritten, and
  crash/partition staging blobs, aren't swept yet.
- **No metrics/telemetry, health endpoints, bitrot scrub, or LIST pagination.**

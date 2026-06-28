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
| `AETHER_ACCESS_KEY` | `AKIAEXAMPLE` | S3 access key (development default). |
| `AETHER_SECRET_KEY` | `devsecret` | S3 secret key (development default). |
| `AETHER_REPLICATION_FACTOR` | `3` | Number of replicas per object. |
| `AETHER_WRITE_QUORUM` | `1` | Replicas that must ack before a PUT returns: an integer, `quorum`, or `all`. Higher = more durable, less available. |
| `AETHER_PEERS` | _(unset)_ | Comma-separated static node list → Epmd discovery (e.g. `aether@n1,aether@n2`). |
| `AETHER_DNS_QUERY` | _(unset)_ | DNS name → DNSPoll discovery (resolve to peer IPs). |
| `AETHER_GOSSIP` | _(unset)_ | `true` → Gossip discovery (UDP multicast on the LAN; good for VMs). |
| `AETHER_GOSSIP_SECRET` | _(unset)_ | Optional shared secret encrypting gossip, so only nodes that share it join. |
| `AETHER_NODE_BASENAME` | `aether` | Node basename used to build peer node names under DNSPoll. |
| `AETHER_CONFIG` | `/etc/aether_s3/config.toml` | Path to the production TOML config file (see below). |

Discovery precedence: `AETHER_PEERS` → `AETHER_DNS_QUERY` → `AETHER_GOSSIP` → LocalEpmd (same-host dev default).

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

## Tests

```sh
mix test
mix format --check-formatted
mix compile --warnings-as-errors
```

## Status and limitations

Working: replicated writes, range-aware reads with cross-node proxying, fan-out
deletes, scatter-gather listing, the Khepri control plane, libcluster
auto-discovery and Raft auto-join, and an anti-entropy self-healing loop.

Known gaps and future work:

- Control-plane member lifecycle is not fully hardened: a wiped node rejoining,
  evicting dead members, and split-brain merge all need work. Today a Khepri
  `join` makes the joiner adopt the cluster's state and discard its own, so a
  control-plane write during the brief formation window can be lost.
- No metrics/telemetry export yet.
- Orphaned blob sweeping is not implemented.

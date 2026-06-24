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
| `AETHER_DNS_QUERY` | _(unset)_ | If set, use DNSPoll discovery against this DNS name; otherwise LocalEpmd (same-host). |
| `AETHER_NODE_BASENAME` | `aether` | Node basename used to build peer node names under DNSPoll. |

BEAM/release variables also apply: `RELEASE_NODE`, `RELEASE_COOKIE`,
`RELEASE_DISTRIBUTION`.

The default credentials are for local development only. Set real ones, turn on
auth, and use a private cookie before exposing a node.

## Cluster discovery across machines

The discovery strategy is chosen at runtime from the environment:

- **No `AETHER_DNS_QUERY`** → LocalEpmd, same-host only (local dev).
- **`AETHER_DNS_QUERY` set** → DNSPoll, which resolves that name to all peer IPs
  and connects to `<basename>@<ip>`. This is what works across containers, real
  machines behind a headless DNS record, and Kubernetes.

For deployments across separate machines, each node's name must use an IP or
hostname the other nodes can actually reach, the cookie must match, and epmd
(4369) plus the distribution port range (9100–9110) must be open between nodes.

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
- Multipart uploads are not yet cluster-aware.
- No read-repair on the read path (anti-entropy handles drift in the
  background).
- No metrics/telemetry export yet.
- Orphaned blob sweeping is not implemented.

# AetherS3

A self-hostable, distributed, S3-compatible object store that runs on the BEAM.

AetherS3 stores objects across a cluster of nodes and speaks enough of the S3
HTTP API to be driven by standard S3 clients (bucket and object operations,
range reads, multipart uploads, SigV4 auth). It is built as an Erlang/OTP
application: nodes discover each other, replicate object data, and self-heal
without an external coordinator.

This is a learning project. See [Status and limitations](#status-and-limitations)
before relying on it.

## Requirements

- Elixir `~> 1.20` on Erlang/OTP 29 (for building from source / dev). A
  `mise.toml` pins the toolchain.
- Docker, to run a cluster the easy way.

## Quick start

Single development node serving the S3 API on port 9000:

```sh
mix deps.get
AETHER_REQUIRE_AUTH=false mix run --no-halt &

curl -X PUT http://localhost:9000/my-bucket                    # create bucket
curl -X PUT http://localhost:9000/my-bucket/hello --data 'hi'  # put object
curl http://localhost:9000/my-bucket/hello                     # get object
curl http://localhost:9000/my-bucket                           # list bucket
```

(`AETHER_REQUIRE_AUTH=false` skips signing for the smoke test; real clients send
signed SigV4 requests — see [Security](docs/security.md).)

A three-node cluster with Docker:

```sh
docker compose up --build --scale aether=3
```

Each container names itself `aether@<container-ip>` and discovers peers via
DNSPoll, forming a Raft cluster on startup. The object API is on port 9000.

## Web console

A separate app, `aether_console`, provides a web UI to manage identities and
buckets and watch the cluster live (nodes, leader, replica flow). It runs as its
own release and talks to the cluster over HTTP. See [Web console](docs/console.md)
to run it locally or deploy it in front of a cluster.

## Documentation

| Guide | What's in it |
| --- | --- |
| [Architecture](docs/architecture.md) | The two planes (AP data / CP control), HRW placement, replication, read-repair, anti-entropy & rebalancing, conflict resolution, storage layout. |
| [Security](docs/security.md) | SigV4 auth, identities & keys, authorization (owner + grants + groups), the admin API, TLS, and a hardening checklist. |
| [Configuration](docs/configuration.md) | Every environment variable, live log level, and the production TOML file. |
| [Clustering](docs/clustering.md) | Discovery strategies, node name & cookie, ports, LAN/Proxmox deploys, supervision & control-plane self-healing. |
| [Observability](docs/observability.md) | Health/readiness/metrics/cluster endpoints and the Prometheus + Grafana showcase. |
| [Web console](docs/console.md) | The `aether_console` UI — live cluster/replica-flow view, bucket & identity management, config, running it, security posture. |
| [Development](docs/development.md) | Building, releases, and the unit + end-to-end test suites. |

## Status and limitations

**Working:** replicated writes with a configurable write quorum, range-aware
reads with cross-node proxying and read-repair, version-vector conflict
resolution, fan-out deletes, scatter-gather listing, the Khepri control plane
with libcluster auto-discovery + Raft auto-join, dead-member eviction and
boot-time self-heal, an anti-entropy loop that also rebalances (migrates *and*
sheds) on topology change, reaping of abandoned multipart uploads, **SigV4
authentication with per-bucket authorization (owner + grants + groups), a
token-gated admin API for identities/groups, and optional in-app TLS**,
Prometheus metrics + health/readiness endpoints, and an end-to-end test suite
(same-host, Docker, split-brain, rebalance, reaping) that runs in CI.

**Known gaps and future work:**

- **Formation-window write loss (control plane):** a control-plane write in the
  ~1 s before initial Raft membership stabilizes can be lost. Steady-state
  partitions are fine — a reconnecting member *resyncs*, it doesn't re-join.
- **Conflict resolution is single-value:** concurrent writes to the same key
  converge to one version (version vectors detect the conflict, but S3 can't
  expose siblings, so the losing write is discarded).
- **Orphan cleanup:** abandoned multipart uploads and crashed-write staging temps
  are swept, but parts orphaned when a manifest is *overwritten* aren't yet.
- **Authorization is grant-based, not a full policy engine** (no deny rules /
  wildcards / conditions); groups are flat. Object data isn't encrypted at rest.
- **No bitrot scrub, no LIST pagination, no distributed tracing.**

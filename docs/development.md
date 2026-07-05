# Development

## Building from source

```sh
mix deps.get
mix compile
```

Requires Elixir `~> 1.20` on Erlang/OTP 29. A `mise.toml` pins the toolchain —
`mise install` sets it up to match CI and the release builds.

## Releases

`mix rel` produces a plain OTP release folder under `_build/prod/rel/aether_s3`
(this is what the Docker image ships). It bundles ERTS, so the target host needs
no Erlang/Elixir:

```sh
MIX_ENV=prod mix rel

RELEASE_NODE=aether@127.0.0.1 RELEASE_COOKIE=secret \
  _build/prod/rel/aether_s3/bin/aether_s3 start
```

A single self-contained binary per target (Burrito, needs `zig`):

```sh
BURRITO_BUILD=1 MIX_ENV=prod mix rel
# -> burrito_out/aether_s3_macos, burrito_out/aether_s3_linux
```

The `release` CI workflow builds native tarballs for
linux-{x86_64,aarch64}-{gnu,musl} and macos-aarch64, and publishes multi-arch
Docker images, on a `v*` tag.

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
test/e2e/split_brain.sh     # partitions a 3-node cluster, proves recovery
test/e2e/rebalance.sh       # grows 3->5 nodes, proves migration + orphan shedding
test/e2e/reap.sh            # proves abandoned multipart uploads are swept past the age grace
```

`rebalance.sh` writes a batch to a 3-node cluster, adds 2 more nodes, and asserts
anti-entropy **migrates** objects to the new HRW owners *and* **sheds** them from
nodes that are no longer replicas — verified by the total copy count staying at
`objects × replication_factor` while the new nodes receive data.

`split_brain.sh` partitions the cluster (an `iptables` sidecar in each minority
node's network namespace) and asserts both recovery behaviors: the **control
plane** (Raft) keeps quorum on the majority and the minority's bucket-create does
not reach the consistent log during the split, then resyncs on heal; and the
**data plane** (AP) takes divergent same-key writes on both sides (W=1) and
**converges to the last-writer-wins value** on heal.

It defaults to a 3-node split (majority {1,2} vs lone node {3}) but is
parameterizable for any split — e.g. a 5-node 3-vs-2 split where *both* sides are
multi-node sub-clusters:

```sh
SB_COMPOSE=docker-compose.static5.yml SB_PROJECT=aether-split5 \
SB_MAJORITY="1 2 3" SB_MINORITY="4 5" test/e2e/split_brain.sh
```

# Configuration

Runtime configuration is via environment variables (the dev/default path) or a
TOML file (production). Node **name** and **cookie** are BEAM-level and set
separately — see [Clustering](clustering.md).

## Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `AETHER_PORT` | `9000` | S3 API listen port. |
| `AETHER_ADMIN_PORT` | `9001` | Operational + admin-API port (`/health`, `/ready`, `/ready/cp`, `/metrics`, `/cluster`, `/admin/*`). Firewall it. |
| `AETHER_DATA_DIR` | `tmp/aether_data` | Where blobs, metadata, and the Khepri log live. One per node. |
| `AETHER_LOG_LEVEL` | `info` | Log level (`debug`, `info`, `warning`, `error`, …). Changeable live (below). |
| `AETHER_REPLICATION_FACTOR` | `3` | Number of replicas per object. |
| `AETHER_WRITE_QUORUM` | `1` | Replicas that must ack before a PUT returns: an integer, `quorum`, or `all`. Higher = more durable, less available. |
| **Security** | | (see [Security](security.md)) |
| `AETHER_REQUIRE_AUTH` | `true` | SigV4 auth + authorization on/off. `false` disables the whole security layer (dev only). |
| `AETHER_ROOT_ACCESS_KEY` | `AKIAEXAMPLE` | Config-seeded root access key. **Change for production.** |
| `AETHER_ROOT_SECRET_KEY` | `devsecret` | Config-seeded root secret. **Change for production.** |
| `AETHER_MASTER_KEY` | _(unset)_ | Passphrase that encrypts minted key secrets at rest. Required to use dynamic keys; identical on every node. |
| `AETHER_ADMIN_TOKEN` | _(unset)_ | Bearer token for the admin identity/group API. Unset = that API is disabled. |
| `AETHER_TLS_CERT` | _(unset)_ | PEM cert path — set with `AETHER_TLS_KEY` to serve the S3 API over HTTPS. |
| `AETHER_TLS_KEY` | _(unset)_ | PEM key path (paired with `AETHER_TLS_CERT`). |
| **Discovery** | | (see [Clustering](clustering.md)) |
| `AETHER_PEERS` | _(unset)_ | Comma-separated static node list → Epmd discovery. |
| `AETHER_DNS_QUERY` | _(unset)_ | DNS name → DNSPoll discovery. |
| `AETHER_GOSSIP` | _(unset)_ | `true` → Gossip discovery (UDP multicast on the LAN). |
| `AETHER_GOSSIP_SECRET` | _(unset)_ | Optional shared secret encrypting gossip. |
| `AETHER_NODE_BASENAME` | `aether` | Node basename for building peer names under DNSPoll. |
| **Maintenance** | | |
| `AETHER_CP_CACHE_TTL_MS` | `1000` | Milliseconds to cache hot control-plane lookups (creds, identity, bucket, groups) so authenticated requests skip a leader round-trip and survive a brief CP outage. Higher = fewer CP reads but staler auth/ACLs; `0` disables (always read the CP). |
| `AETHER_CP_EVICT_GRACE` | _(unset)_ | Seconds an unreachable control-plane member waits before the Raft leader evicts it. Opt-in. |
| `AETHER_MPU_REAP_AGE` | _(unset)_ | Seconds after which an abandoned multipart upload is swept. Opt-in. |
| `AETHER_STAGING_SWEEP_AGE` | `3600` | Seconds a crashed-write staging temp must age before reclaim. Always on. |
| **Durability & integrity** | | (see [Architecture](architecture.md)) |
| `AETHER_OBJMETA_SYNC` | `group` | Object-metadata write mode. `group` group-commits — a put blocks until a batched fsync (same durability as per-write fsync, higher throughput); `each` = per-write fsync. |
| `AETHER_SCRUB_INTERVAL` | _(unset)_ | Seconds between background bitrot-scrub passes (re-read every local blob, verify its md5 vs etag, heal a mismatch from a replica). Opt-in. |
| `AETHER_VERIFY_READS` | `false` | `true` verifies each full local GET against its etag while streaming, aborting the response + healing on a mismatch (whole-object md5 per read has a CPU cost). |
| `AETHER_SHUTDOWN_DRAIN_MS` | `5000` | Graceful-shutdown drain window (ms): on shutdown, flip `/ready` to 503 and wait this long before draining in-flight requests so a load balancer stops routing here first. |
| `AETHER_CONFIG` | `/etc/aether_s3/config.toml` | Path to the production TOML config (below). |

Discovery precedence: `AETHER_PEERS` → `AETHER_DNS_QUERY` → `AETHER_GOSSIP` →
LocalEpmd (same-host dev default).

### Graceful shutdown

On `SIGTERM` (rolling deploy, `docker stop`, k8s pod eviction) the node drains
gracefully: it flips `/ready` to `503` so a load balancer stops routing new
traffic (while `/health` stays `200`), waits `AETHER_SHUTDOWN_DRAIN_MS`
(default 5000) for the LB to notice, then stops accepting connections and lets
in-flight requests finish before tearing down.

**Give the orchestrator enough termination grace.** The total shutdown budget is
`AETHER_SHUTDOWN_DRAIN_MS` **plus** the in-flight-request drain (up to ~25–30 s
for large transfers). Set the platform's grace period at least that high, or the
node is `SIGKILL`ed mid-drain and the graceful path is wasted:

- Docker: `docker stop --time <seconds>` (default is only **10 s**).
- Compose: `stop_grace_period`.
- Kubernetes: `terminationGracePeriodSeconds` (default **30 s**).

### Live log level

Change the log level on a **running** node without a restart (e.g. to capture
debug output during an incident) via the release remote shell:

```sh
bin/aether_s3 rpc 'AetherS3.Config.set_log_level("debug")'
```

## Production config file (TOML)

For production, drop a TOML file at `AETHER_CONFIG`; when present, its values
override the environment. See `config.toml.example` for the full schema.

```toml
port = 9000
data_dir = "/var/lib/aether_s3"
replication_factor = 3
write_quorum = "quorum"
require_auth = true

# In-app TLS (omit to terminate at a Host-preserving proxy)
# tls_cert = "/etc/aether_s3/tls/cert.pem"
# tls_key  = "/etc/aether_s3/tls/key.pem"

master_key = "a-long-random-passphrase"   # encrypts minted key secrets
# admin_token = "a-long-random-token"      # only if using the admin API

# Config-seeded root identity (user defaults to "root", admin to true)
[[root_identities]]
access_key = "AKIA_ROOT"
secret_key = "change-me"

[cluster]
strategy = "dns"          # "dns" | "epmd" (static list) | "gossip" (LAN multicast)
dns_query = "aether.internal"
node_basename = "aether"
# peers  = ["aether@n1.lan", "aether@n2.lan"]   # for "epmd"
# secret = "shared-gossip-secret"                # for "gossip"
```

For Docker, mount the file in (`-v ./config.toml:/etc/aether_s3/config.toml`).
The node **name** and **cookie** are BEAM-level (`RELEASE_NODE` /
`rel/vm.args.eex` and `RELEASE_COOKIE` / `~/.erlang.cookie`), not this file.

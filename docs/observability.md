# Observability

Each node serves operational endpoints on `AETHER_ADMIN_PORT` (default 9001),
separate from the S3 API so they need no SigV4 signature and can be firewalled
off from public traffic. (The `/admin/*` identity-management API on the same port
*is* token-gated — see [Security](security.md).)

| Endpoint | Purpose |
| --- | --- |
| `GET /health` | Liveness — 200 as long as the process can respond. |
| `GET /ready` | **Data-plane** readiness — 200 if the core services that serve object traffic (the ring + local metadata store) are up, else 503. A node can serve/proxy objects even while the control plane is unavailable, so this is what to gate S3-traffic load balancers on. |
| `GET /ready/cp` | **Control-plane** readiness — 200 only if a bounded, *leader-routed* Khepri probe actually commits (a reachable leader holds quorum). Catches a phantom leader or lost quorum that a cached leaderboard lookup would miss; gate control-plane-aware routing/monitoring on this. |
| `GET /metrics` | Prometheus exposition. |
| `GET /cluster` | Best-effort JSON snapshot of every node's view (leader, per-node membership + object counts). Fans out via `erpc`; marks unreachable peers, so a partition is visible at a glance. |
| `GET /whoami` | SigV4-authenticated identity check — returns the signing caller's `{user, admin}` as JSON. Per-user (unlike the token-gated `/admin/*`), so a tool such as the [web console](console.md) can verify a login credential. |

Metrics exported today: S3 request latency + counts
(`bandit_request_duration_milliseconds`, tagged by method/status), domain
counters (object PUT/GET/DELETE, read-repair, anti-entropy repair/shed, reaper,
multipart lifecycle), BEAM VM stats (`vm_memory_total`, run-queue, process
count), and per-node cluster gauges (`aether_cluster_nodes`,
`aether_cluster_khepri_leader`, `aether_cluster_objects`).

Metrics are **per node** by design — the cluster-wide view comes from scraping
every node and aggregating in PromQL (e.g. `sum(aether_cluster_objects)`, or
`max(aether_cluster_nodes) - min(...)` to spot a partition). For a quick look
without Prometheus, `GET /cluster` returns every node's view in one JSON
document.

## Distributed tracing (OpenTelemetry)

Metrics tell you aggregate rates and latencies; tracing tells you where a *single*
request spent its time — including the work it fanned out to other nodes. AetherS3
emits OpenTelemetry spans for the S3 write path and propagates trace context across
the replication hop, so one PUT is a single trace spanning every node it touched.

**Off by default, zero cost.** Tracing is inert unless an OTLP endpoint is set —
no spans, no sampling, no context injection on the hot path. Enable it by pointing
at an OTLP/HTTP collector:

| Env | Meaning |
| --- | --- |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP/HTTP collector base URL (e.g. `http://collector:4318`). Setting it turns tracing on. |
| `OTEL_SERVICE_NAME` | Service name in the trace UI (default `aether_s3`). |
| `OTEL_TRACES_SAMPLER_ARG` | Head sampling ratio `0.0`–`1.0` for production; unset samples every trace. |

A PUT produces this span tree (the last span runs on the *replica* node, linked
into the same trace):

```
PUT                       inbound S3 request
├─ storage.ingest         read + checksum + write the body
└─ replica.push_blob      synchronous replica push (one per quorum replica)
   └─ receiver.finish     the replica's persist — a SERVER span on that node
```

The cross-node link is deliberate: `:erpc` runs the callee in a fresh process on
the remote node with none of the caller's context, so `AetherS3.Tracing.rpc/4`
injects the active context into a W3C carrier, ships it as an argument, and
re-attaches it on the far side before opening the span. Without that, the
replica's work would be an orphan trace.

**View it locally:** `bench/compose.tracing.yml` boots a traced cluster wired to
an all-in-one Jaeger — `docker compose -f bench/compose.tracing.yml up -d --scale
aether=3`, send an S3 request, and open <http://localhost:16686>.

Scope today: the synchronous (quorum) replica pushes are traced; best-effort
background replication and the admin port are not yet instrumented.

## Telemetry showcase (Prometheus + Grafana)

A self-contained stack — a 3-node cluster plus Prometheus (scraping every node's
`/metrics`) plus Grafana with a pre-provisioned datasource and dashboard:

```sh
docker compose -f docker-compose.observability.yml up --build
```

Open Grafana at http://localhost:3000 (anonymous admin, no login) — the
"AetherS3 — Cluster Overview" dashboard is already loaded (nodes up, cluster
size, leader present, objects per node, S3 request rate/latency, self-healing
activity, VM memory). Prometheus is at http://localhost:9090. Node 1's S3 API is
published on `localhost:9000`; drive some traffic and watch the panels move:

```sh
curl -X PUT http://localhost:9000/demo
for i in $(seq 1 50); do curl -sX PUT --data "v$i" http://localhost:9000/demo/o$i >/dev/null; done
```

The monitoring config lives in `monitoring/` (Prometheus scrape config + Grafana
provisioning + the dashboard JSON), so the dashboard is version-controlled and
editable.

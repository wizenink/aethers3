# Observability

Each node serves operational endpoints on `AETHER_ADMIN_PORT` (default 9001),
separate from the S3 API so they need no SigV4 signature and can be firewalled
off from public traffic. (The `/admin/*` identity-management API on the same port
*is* token-gated — see [Security](security.md).)

| Endpoint | Purpose |
| --- | --- |
| `GET /health` | Liveness — 200 as long as the process can respond. |
| `GET /ready` | Readiness — 200 once this node knows a Khepri/Raft leader (can serve the control plane), else 503. Use it for load-balancer / k8s probes. |
| `GET /metrics` | Prometheus exposition. |
| `GET /cluster` | Best-effort JSON snapshot of every node's view (leader, per-node membership + object counts). Fans out via `erpc`; marks unreachable peers, so a partition is visible at a glance. |

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

# Web console

`aether_console` is a web UI for operating and watching an AetherS3 cluster: a live
topology and replica-flow view, plus bucket and identity management. It is a
**separate Phoenix LiveView app and release** — a pure HTTP client of the cluster's
admin port (default 9001). It never joins the BEAM cluster and never touches the S3
data port, so it adds no coupling and no trust surface to the storage nodes.

```
┌────────────┐   HTTP (admin port 9001)    ┌──────────────────────────┐
│ browser    │◀──LiveView (websocket)──▶  │ aether_console (Phoenix) │
└────────────┘                            └────────────┬─────────────┘
                        GET /cluster  (tokenless)      │
                        GET /whoami   (SigV4 login)    │
                        /admin/*      (bearer token)   ▼
                                          ┌──────────────────────────┐
                                          │  any storage node :9001  │
                                          └──────────────────────────┘
```

**One reachable node is enough.** A single node's `/cluster` isn't just *that*
node's view — the cluster status endpoint fans out to every member and consolidates
leader, membership, and per-node counts server-side, so one response describes the
whole cluster. Writes go through the Khepri control plane and replicate cluster-wide,
so it doesn't matter which node handles them either. `AETHER_CONSOLE_NODES` is
therefore a **failover list, not an aggregation list**: the console uses the first
URL that answers, and extra entries only matter if that node is down.

## Views

| View | Source | What it does |
| --- | --- | --- |
| **Cluster** | `GET /cluster` | Live topology — nodes, leader, per-node object counts. An animated field draws a particle per real replication event, so self-healing is visible as it happens. Polls every 1.5 s. |
| **Buckets** | `/admin/buckets` | List buckets; create (DNS-name validated) and delete (empty only). |
| **Identity** | `/admin/users`, `/admin/keys`, `/admin/groups` | Tabbed Users / Keys / Groups. Create/delete users, mint/revoke access keys, create/delete groups, add/remove members. A minted secret is shown once. |
| **Objects** | — | Placeholder — no object browser yet. |

The Cluster view needs no token. Buckets and Identity call the token-gated
`/admin/*` API; if `AETHER_CONSOLE_ADMIN_TOKEN` is unset they render a "not
configured" state rather than erroring.

The particle flow is not simulated. Each node's `/cluster` payload carries
cumulative op counters (`put`, `repair`, `read_repair`, `shed`); the console diffs
them between polls and emits a bounded number of particles proportional to each op's
rate. An idle cluster is still; an unreachable one says so. See
[Observability](observability.md) for the underlying counters.

## Authentication

Operators log in **as a cluster identity** — the console keeps no user store of its
own. The default `cluster` strategy verifies an access key and secret against the
cluster: it SigV4-signs `GET /whoami` on the admin port and reads back the caller's
`{user, admin}`. The console never holds the master key, so it cannot verify secrets
itself — the cluster does.

- Every console route is behind the login gate; an unauthenticated request redirects
  to `/login`. Only the resolved `{user, admin}` is stored in the session cookie
  (signed with `AETHER_CONSOLE_SECRET_KEY_BASE`). The secret proves identity at login
  and is then discarded, never persisted.
- **Admin is required.** Every view currently uses the cluster admin token, so login
  requires an `admin: true` identity; a valid non-admin credential is rejected.
  Self-service for regular users (scoped to their own buckets via the S3 API) is a
  planned next step.
- On a cluster running with `AETHER_REQUIRE_AUTH=false` (development), `/whoami`
  cannot identify a caller, so console login is open — matching the cluster's own
  posture.
- `oidc` is reserved as a future `AETHER_CONSOLE_AUTH` strategy.

## Configuration

The console is configured entirely by environment variables. It shares
`config/runtime.exs` with the storage release, but each ignores the other's
variables.

| Variable | Default | Purpose |
| --- | --- | --- |
| `AETHER_CONSOLE_NODES` | `http://localhost:9001` | Comma-separated admin base URLs, used as a failover list (one reachable node describes the whole cluster). The console uses the first that answers; a single URL works fine. |
| `AETHER_CONSOLE_ADMIN_TOKEN` | _(unset)_ | Bearer token for the cluster's `/admin/*` API. Must equal the cluster's `AETHER_ADMIN_TOKEN`. Unset → Buckets/Identity show "not configured". |
| `AETHER_CONSOLE_AUTH` | `cluster` | Login strategy. `cluster` verifies an access key + secret against the cluster; `oidc` is reserved. |
| `AETHER_CONSOLE_SECRET_KEY_BASE` | _(unset)_ | **Required in production.** Random string that signs the console's own session cookies. Generate with `mix phx.gen.secret` or `openssl rand -base64 48`. Not shared with anyone; keep it stable across restarts. |
| `AETHER_CONSOLE_HOST` | `localhost` | Hostname for URL generation and the default websocket origin check. |
| `AETHER_CONSOLE_PORT` | `4000` | HTTP listen port. |
| `AETHER_CONSOLE_CHECK_ORIGIN` | _(host)_ | Websocket origin allowlist. Defaults to `//$AETHER_CONSOLE_HOST`; set a comma list to allow more, or `false` to disable (e.g. behind a trusted proxy). |

The console handles two distinct secrets. `AETHER_CONSOLE_SECRET_KEY_BASE` is a
random value that signs the console's own browser cookies — the cluster never sees
it. `AETHER_CONSOLE_ADMIN_TOKEN` is the shared secret that authenticates the console
*to* the cluster, and must match the cluster's `AETHER_ADMIN_TOKEN`. Minting keys
additionally requires `AETHER_MASTER_KEY` on the cluster. See
[Configuration](configuration.md) and [Security](security.md).

## Running locally

Point the console at a local storage node and start it from the **console app
directory** — starting from the umbrella root would also boot a storage node:

```sh
cd apps/aether_console
AETHER_CONSOLE_NODES=http://localhost:9001 \
AETHER_CONSOLE_ADMIN_TOKEN=devtoken \
  mix phx.server            # http://localhost:4000
```

Dev config (port, a throwaway `secret_key_base`, the esbuild asset watcher) lives in
`config/config.exs` under the `:dev` block, so no production variables are needed. If
the node runs with `AETHER_REQUIRE_AUTH=false`, login is open; run it with auth on to
exercise the real login flow.

Against a Docker cluster, `docker-compose.console.yml` overlays
`docker-compose.static5.yml` to set an admin token and master key on one node.
Container ports are not published; reach the node by its IP:

```sh
docker compose -f docker-compose.static5.yml -f docker-compose.console.yml up -d
IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' aether-static5-aether1-1)

cd apps/aether_console
AETHER_CONSOLE_NODES=http://$IP:9001 AETHER_CONSOLE_ADMIN_TOKEN=consoletoken \
  mix phx.server
```

## Deploying with a cluster

End to end: a running cluster and the console in front of it.

**1. Run the cluster with auth on and a master key + admin token.** Follow
[Clustering](clustering.md) to form the cluster, and set these on every node (see
[Configuration](configuration.md) and the [Security](security.md) hardening
checklist):

```sh
AETHER_REQUIRE_AUTH=true \            # the default
AETHER_ROOT_ACCESS_KEY=AKIA... \      # a real root identity to log in with
AETHER_ROOT_SECRET_KEY=<root-secret> \
AETHER_MASTER_KEY=<shared-master-key> \       # identical on every node; encrypts minted secrets
AETHER_ADMIN_TOKEN=<admin-token> \            # gates the /admin API the console drives
  bin/aether_s3 start
```

**2. Build and run the console release.** It bundles only `:aether_console` (never
the storage app). Build the assets first, then assemble:

```sh
MIX_ENV=prod mix esbuild aether_console --minify     # -> priv/static/assets/{app.js,app.css}
MIX_ENV=prod mix release aether_console

AETHER_CONSOLE_SECRET_KEY_BASE="$(openssl rand -base64 48)" \
AETHER_CONSOLE_NODES="http://node1:9001,http://node2:9001" \
AETHER_CONSOLE_ADMIN_TOKEN="<admin-token>" \         # must match the cluster's AETHER_ADMIN_TOKEN
AETHER_CONSOLE_HOST="console.internal" \
  _build/prod/rel/aether_console/bin/aether_console start
```

The release refuses to boot without `AETHER_CONSOLE_SECRET_KEY_BASE` — a deliberate
fail-closed default.

**3. Open the console and log in** at `http://console.internal:4000` with an admin
access key and secret — the root identity from step 1, or any admin key minted via
the admin API or the console's Identity view. Non-admin credentials are rejected.

## Security posture

The console is a trust concentrator: it holds the cluster admin token and, once an
operator is logged in, can create/delete buckets, mint/revoke keys, and delete users.

- Login requires a cluster **admin** identity, but the console still calls `/admin/*`
  with the shared token — so bind it to an internal network and/or front it with a
  TLS-terminating reverse proxy for anything non-local.
- Give the console its own admin token (shared only with the cluster's
  `AETHER_ADMIN_TOKEN`) and rotate it independently of S3 credentials.
- Keep `AETHER_CONSOLE_SECRET_KEY_BASE` secret and stable — it signs the session
  cookie that represents a logged-in admin.

See [Security](security.md) for the cluster-side admin API, identities, and the
hardening checklist.

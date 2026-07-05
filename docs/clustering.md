# Clustering

Discovery decides how nodes *find* each other's names; once found, every strategy
connects over the same BEAM distribution transport. Two things always apply:

- **Node name must be an IP or an FQDN** (contain a dot). With long-name
  distribution a bare short hostname like `aether1` is rejected
  (`Hostname ... illegal`) — use `aether@10.0.0.5` or `aether@n1.lan`.
- **Same cookie** on every node.

## Node name & cookie

These are BEAM-level (set before the app boots, so they can't go in the TOML
file). Use the friendly aliases `AETHER_NODE` / `AETHER_COOKIE`, or the
underlying `RELEASE_NODE` / `RELEASE_COOKIE` (an explicit `RELEASE_*` wins).
`RELEASE_DISTRIBUTION` defaults to `name`.

The cookie can also be a `~/.erlang.cookie` file (mode 0400), which is the
**preferred production approach** (env vars are visible in `ps`). Aliases are
wired in `rel/env.sh.eex` (Linux and macOS; Windows would need `rel/env.bat.eex`).

## Discovery strategies

Chosen at runtime (env or the TOML `[cluster]` block):

| Strategy | Trigger | Best for |
| --- | --- | --- |
| LocalEpmd | _(default)_ | same-host dev |
| Epmd (static) | `AETHER_PEERS=aether@n1.lan,aether@n2.lan,...` | fixed, stable-name nodes |
| DNSPoll | `AETHER_DNS_QUERY=<dns-name>` | containers / k8s (headless service) |
| Gossip | `AETHER_GOSSIP=true` | VMs on one LAN (auto-discovery) |

Precedence: `AETHER_PEERS` → `AETHER_DNS_QUERY` → `AETHER_GOSSIP` → LocalEpmd.

## Ports

Between **nodes** (on top of the per-strategy channel): epmd **TCP 4369** and the
distribution range **TCP 9100–9110** (pinned in `rel/vm.args.eex`). Per-strategy
discovery channel: DNSPoll → DNS (53); Gossip → **UDP 45892 multicast**;
Epmd/LocalEpmd → none extra. The S3 API (9000) is client-facing and unrelated to
clustering; the admin port (9001) should be firewalled to operators.

## Running on a LAN of VMs (e.g. Proxmox) with Gossip

Gossip auto-discovers peers via UDP multicast — no static list or DNS. On each
VM, run the release with:

```sh
AETHER_NODE=aether@<this-vm-ip> \
AETHER_COOKIE=<shared-secret> \
AETHER_GOSSIP=true \
AETHER_GOSSIP_SECRET=<shared-gossip-secret> \
AETHER_DATA_DIR=/var/lib/aether_s3 \
  bin/aether_s3 start
```

The VMs must share an L2 network so multicast reaches them (Proxmox VMs on the
same bridge/VLAN do), with UDP 45892 + TCP 4369 + 9100–9110 open between them. If
you run it as a **Docker** container on each VM, use host networking
(`network_mode: host`) — bridged Docker NAT breaks cross-host multicast and
distribution.

## Process supervision & self-healing

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

Control-plane member lifecycle does **not** depend on this: dead members are
evicted by the Raft leader after `AETHER_CP_EVICT_GRACE` (opt-in), and an evicted
node heals itself **at boot** — before starting Khepri it checks with a peer and
wipes its stale Raft state if it was removed, then rejoins cleanly. No external
restart is needed for that path; only the control-plane log is wiped (blobs and
object metadata are untouched and re-sync from the leader).

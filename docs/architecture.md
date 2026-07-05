# Architecture

AetherS3 is an Erlang/OTP application: nodes discover each other, replicate
object data, and self-heal without an external coordinator. The system splits
into two planes with different consistency models.

## Data plane (AP)

Object blobs and their metadata. Placement is decided by **rendezvous (HRW)
hashing**: every node independently computes the same ordered list of replica
nodes for a given `{bucket, key}`, so there is no placement registry to keep in
sync.

- **Writes** are accepted as soon as the write quorum is durable. `W` is
  configurable (`AETHER_WRITE_QUORUM`: an integer, `quorum`, or `all`, resolved
  against the replication factor). The default `W=1` returns after one replica
  is durable; the rest are filled asynchronously.
- **Reads** locate a live replica and stream the object back. If the node that
  received the request does not hold a copy, it proxies the bytes from a peer
  over Erlang distribution, chunk by chunk (constant memory). Range requests are
  served by seeking within the object.
- **Read-repair**: on the read path, replicas that are missing or stale are
  repaired asynchronously toward the freshest version.
- **Anti-entropy** continuously repairs drift and, on a topology change,
  **rebalances**: it migrates objects to their new HRW owners *and* sheds copies
  from nodes that are no longer replicas (never dropping the last copy).

Blobs are written to a unique temp path and atomically renamed into place, so a
crash leaves an orphan temp, never a half-written object.

### Conflict resolution

Writes carry **version vectors**. A causal descendant wins; genuinely concurrent
writes fall back to a deterministic last-writer-wins tiebreak. The S3 API can't
expose siblings, so a conflict resolves to a single value rather than being
merged.

## Control plane (CP)

Bucket existence, ownership, ACL grants, groups, and identities — metadata that
must be globally consistent. Backed by **Khepri** (a Raft/`ra` tree store), so
these go through consensus. libcluster discovers membership and the control
plane auto-joins the Raft cluster on startup.

Member lifecycle is self-managing: dead members are evicted by the Raft leader
after a grace period (opt-in), and an evicted node heals itself **at boot** —
before starting Khepri it checks with a peer and wipes its stale Raft state if it
was removed, then rejoins cleanly. Only the control-plane log is wiped; blobs and
object metadata are untouched and re-sync from the leader.

## Storage layout

| Data | Store |
| --- | --- |
| Object blobs | Local disk, under `AETHER_DATA_DIR` |
| Object metadata | Embedded CubDB store |
| Control-plane tree | Khepri's Ra log |

The multipart-upload model stores each completed object as a *manifest* whose
metadata carries a `:parts` list; the part bytes live as ordinary replicated
objects under a reserved bucket. See [Security](security.md) for how that
reserved bucket is isolated from clients.

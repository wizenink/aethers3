# Security

AetherS3 authenticates every S3 request with **AWS Signature V4** and authorizes
it against per-bucket ownership and grants. Identities and grants live in the
control plane, so they replicate to every node.

> Auth is on by default. Setting `AETHER_REQUIRE_AUTH=false` turns off the
> **entire** security layer (authentication *and* authorization) — it does not
> elevate callers to admin. Use it only for local development.

## Authentication

Requests are signed with SigV4; the server resolves the request's access key to
a secret and recomputes the signature (constant-time compare). The `x-amz-date`
must be within a ±5-minute window, so a captured signature can't be replayed
later.

Identities come from two places:

- **Config-seeded root** — one or more always-present admin identities, so a
  fresh cluster is usable before any key is minted. Set them via
  `AETHER_ROOT_ACCESS_KEY` / `AETHER_ROOT_SECRET_KEY`, or a `[[root_identities]]`
  table in the TOML config. The root secret lives in config (host-protected),
  not in the store.
- **Dynamic keys** — users and access keys minted at runtime through the
  [admin API](#admin-api). Each key's secret is **encrypted at rest**
  (AES-256-GCM) with a master key (`AETHER_MASTER_KEY`) before it goes into
  Khepri, and decrypted in memory only to verify a signature. Keep the master
  key identical on every node.

A user owns any number of access keys (rotate by minting a new one and revoking
the old). Deleting a user cascades its keys.

## Authorization

Once authenticated, a request is decided in this order:

1. **admin identity** → allowed.
2. **bucket owner** (the identity that created it) → allowed on that bucket.
3. otherwise, the bucket's **grants** must allow the operation's permission for
   one of the caller's *principals*.

A caller's principals are their **user**, every **group** they belong to, and
**everyone**. An anonymous (unsigned) request is just `everyone`.

Grants are `{grantee, permission}`:

| Grantee | Permission | Covers |
| --- | --- | --- |
| `{:user, name}` / `{:group, name}` / `:everyone` | `:list` | list / HEAD the **bucket** |
| | `:get` | download / HEAD an **object** |
| | `:write` | object PUT / POST / DELETE |
| | `:full` | all three |

`:list` and `:get` are deliberately separate: a public bucket can serve object
downloads **without** exposing its index. Bucket **create** requires an
authenticated identity (no owner exists yet); bucket **delete** is owner/admin-only
and is never granted by an ACL.

**Canned ACLs** are sugar over grants: `public-read` = an `:everyone` **`:get`**
grant (downloads only, *not* listing — this diverges from S3 on purpose to avoid
leaking the index), `public-read-write` = `:everyone` `:get` + `:write`,
`private` = no grants. To expose a public index, grant `:list` explicitly.

### Setting grants (S3 API)

A bucket **owner** self-serves sharing via `PUT /bucket?acl`, using canned or
explicit grant headers (also honored at create time):

```sh
# make a bucket public-read
aws s3api put-bucket-acl --bucket b --acl public-read

# share with a specific user and a group (grantee: id="user" or group="name")
curl -X PUT "https://host/b?acl" \
  -H 'x-amz-grant-read: id="alice", group="analysts"' \
  -H 'x-amz-grant-write: id="bob"'   # (signed)
```

Groups themselves (who belongs to them) are defined via the admin API, since
membership is an operator concern.

## Admin API

Dynamic identity and group management is served under `/admin` on the **admin
port**, gated by a bootstrap bearer token (`AETHER_ADMIN_TOKEN`). With no token
configured the API is disabled (every request is 401). The probe endpoints
(`/health`, `/ready`, `/ready/cp`, `/metrics`, `/cluster`) stay open. Writes go through the
control plane, so a user/key/group minted on one node exists cluster-wide.

```sh
T="$AETHER_ADMIN_TOKEN"
BASE=http://node:9001/admin

# users + keys
curl -H "Authorization: Bearer $T" -d '{"name":"alice","admin":false}' $BASE/users
curl -H "Authorization: Bearer $T" -X POST $BASE/users/alice/keys   # -> {access_key, secret_key}  (secret shown once)
curl -H "Authorization: Bearer $T" -X DELETE $BASE/keys/AKIA...      # revoke
curl -H "Authorization: Bearer $T" $BASE/users                      # list

# groups + membership
curl -H "Authorization: Bearer $T" -d '{"name":"analysts"}' $BASE/groups
curl -H "Authorization: Bearer $T" -d '{"user":"alice"}' $BASE/groups/analysts/members
curl -H "Authorization: Bearer $T" -X DELETE $BASE/groups/analysts/members/alice
```

A minted access key + secret can immediately sign S3 requests against any node.

## Transport (TLS)

Set `AETHER_TLS_CERT` and `AETHER_TLS_KEY` (PEM paths) to serve the S3 API over
**HTTPS in-process** — no reverse proxy required. Unset, the S3 API is plain
HTTP; terminate TLS at a reverse proxy instead. The admin port always stays HTTP
(firewall it).

**Reverse-proxy caveat:** SigV4 signs the `Host` header, so a proxy that rewrites
Host breaks signature validation. Configure it to **preserve Host**
(`proxy_set_header Host $host;` in nginx). Node-to-node traffic is separate
(Erlang distribution), not the S3 port.

## Hardening checklist

Before exposing a node:

- Set real **root credentials** (`AETHER_ROOT_*` / `[[root_identities]]`) — the
  defaults (`AKIAEXAMPLE` / `devsecret`) are for local dev only.
- Set a **master key** (`AETHER_MASTER_KEY`), identical on every node, kept out
  of version control.
- Set an **admin token** (`AETHER_ADMIN_TOKEN`) only if you use the admin API;
  otherwise leave it unset so the API stays off.
- Use TLS (in-app or a Host-preserving proxy).
- Set the Erlang **distribution cookie** via `~/.erlang.cookie` (mode 0400)
  rather than an env var (env vars are visible in `ps`).
- **Firewall the admin port** — its probe endpoints are unauthenticated.

The reserved multipart bucket (`__mpu__`) is not client-reachable — requests to
it are answered 404, as if it doesn't exist.

## Not yet covered

- Full IAM-style **policy engine** (deny rules, wildcards, conditions). The grant
  model is deliberately shaped as allow-statements so a policy engine is a future
  extension rather than a rewrite. Groups are flat (no nested groups).
- **Encryption of object data at rest** (only key secrets are encrypted).
- Presigned URLs; per-object ACLs.

#!/usr/bin/env bash
# End-to-end test: 3 AetherS3 nodes on ONE host (LocalEpmd discovery), driven by
# a real S3 client (aws-cli). Exercises the cross-node guarantees: write to one
# node, read from another; multipart through the cluster; delete + list.
#
# Requires: elixir/mix, aws-cli on PATH. Run from anywhere:  test/e2e/same_host.sh
set -euo pipefail

cd "$(dirname "$0")/../.."

COOKIE="aethere2e"
NODES=(aethere1 aethere2 aethere3)
PORTS=(9401 9402 9403)
# Admin (health/metrics) ports — distinct per node since they share this host.
ADMIN_PORTS=(9411 9412 9413)
WORKDIR="$(mktemp -d)"
PIDS=()

export AWS_ACCESS_KEY_ID=AKIAEXAMPLE AWS_SECRET_ACCESS_KEY=devsecret
export AWS_DEFAULT_REGION=us-east-1 AWS_EC2_METADATA_DISABLED=true

log()  { echo "[e2e] $*"; }
fail() { echo "[e2e] FAIL: $*" >&2; exit 1; }

cleanup() {
  local code=$?
  if [ "$code" -ne 0 ]; then
    echo "[e2e] --- node logs (failure) ---" >&2
    for n in "${NODES[@]}"; do echo "=== $n ==="; tail -30 "$WORKDIR/$n.log" 2>/dev/null; done >&2
  fi
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# aws against node at index $1 (0-based); rest of args passed through.
# Endpoint uses 127.0.0.1 (an IP) so boto auto-selects path-style addressing.
awsn() { local i=$1; shift; aws --endpoint-url "http://127.0.0.1:${PORTS[$i]}" "$@"; }

log "compiling..."
mix deps.get >/dev/null
mix compile >/dev/null

log "starting ${#NODES[@]} nodes..."
for i in "${!NODES[@]}"; do
  AETHER_PORT="${PORTS[$i]}" \
  AETHER_ADMIN_PORT="${ADMIN_PORTS[$i]}" \
  AETHER_DATA_DIR="$WORKDIR/${NODES[$i]}-data" \
  AETHER_REQUIRE_AUTH=false \
  AETHER_REPLICATION_FACTOR=3 \
    elixir --sname "${NODES[$i]}" --cookie "$COOKIE" -S mix run --no-halt --no-compile \
      >"$WORKDIR/${NODES[$i]}.log" 2>&1 &
  PIDS+=("$!")
done

log "waiting for 3-node cluster to form..."
for _ in $(seq 1 60); do
  if grep -q "cluster membership (3)" "$WORKDIR/${NODES[0]}.log" 2>/dev/null; then break; fi
  sleep 1
done
grep -q "cluster membership (3)" "$WORKDIR/${NODES[0]}.log" || fail "cluster did not form"
log "cluster formed."

# --- admin endpoints: each node's health + a metrics scrape (also guards the
#     same-host admin-port-collision regression) ---
log "probing admin endpoints (health/ready/metrics)..."
for i in "${!NODES[@]}"; do
  curl -fsS "http://127.0.0.1:${ADMIN_PORTS[$i]}/health" >/dev/null || fail "node $i /health not 200"
done
curl -fsS "http://127.0.0.1:${ADMIN_PORTS[0]}/metrics" | grep -q "aether_cluster_nodes" ||
  fail "metrics missing aether_cluster_nodes"

# Bucket creation goes through Khepri (CP) — retry until the Raft cluster is ready.
log "creating bucket (node 0)..."
for _ in $(seq 1 30); do
  if awsn 0 s3 mb s3://e2e >/dev/null 2>&1; then break; fi
  sleep 1
done
awsn 0 s3api head-bucket --bucket e2e >/dev/null 2>&1 || fail "bucket not created"

# --- small object: write node 0, read node 2 (cross-node) ---
log "PUT small object on node 0, GET from node 2..."
echo "hello aether e2e" > "$WORKDIR/small.txt"
awsn 0 s3 cp "$WORKDIR/small.txt" s3://e2e/small.txt >/dev/null
awsn 2 s3 cp s3://e2e/small.txt "$WORKDIR/small.out" >/dev/null
cmp -s "$WORKDIR/small.txt" "$WORKDIR/small.out" || fail "small object differs across nodes"

# --- multipart: 10MB via node 0 (auto-multipart >8MB), read from node 1 ---
log "multipart upload (node 0), GET from node 1, verify..."
head -c 10485760 /dev/urandom > "$WORKDIR/big.bin"
awsn 0 s3 cp "$WORKDIR/big.bin" s3://e2e/big.bin >/dev/null
awsn 1 s3 cp s3://e2e/big.bin "$WORKDIR/big.out" >/dev/null
cmp -s "$WORKDIR/big.bin" "$WORKDIR/big.out" || fail "multipart object differs across nodes"

etag=$(awsn 2 s3api head-object --bucket e2e --key big.bin --query ETag --output text)
case "$etag" in
  *-*) log "multipart ETag ok: $etag" ;;
  *)   fail "expected multipart ETag (…-N), got $etag" ;;
esac

# --- ranged GET across nodes ---
log "ranged GET (bytes spanning a part boundary) from node 2..."
awsn 2 s3api get-object --bucket e2e --key big.bin --range "bytes=8388600-8388700" \
  "$WORKDIR/slice.out" >/dev/null
dd if="$WORKDIR/big.bin" bs=1 skip=8388600 count=101 2>/dev/null > "$WORKDIR/slice.exp"
cmp -s "$WORKDIR/slice.out" "$WORKDIR/slice.exp" || fail "ranged GET bytes differ"

# --- delete on node 1, confirm gone from node 2 ---
log "DELETE on node 1, confirm 404 on node 2..."
awsn 1 s3 rm s3://e2e/big.bin >/dev/null
if awsn 2 s3api head-object --bucket e2e --key big.bin >/dev/null 2>&1; then
  fail "object still present after delete"
fi

# --- list from node 2 ---
log "LIST from node 2..."
awsn 2 s3 ls s3://e2e/ | grep -q "small.txt" || fail "list missing small.txt"

log "PASS: same-host multi-node e2e"

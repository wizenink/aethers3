#!/usr/bin/env bash
# End-to-end test: a 3-node AetherS3 cluster in Docker (DNSPoll discovery),
# driven by a real S3 client (the official amazon/aws-cli image, run on the
# cluster's network). Same cross-node guarantees as the same-host test, but over
# real containers + the built release image.
#
# Requires: docker (with compose). Run from anywhere:  test/e2e/docker_cluster.sh
set -euo pipefail

cd "$(dirname "$0")/../.."

PROJECT="aethere2e"
COMPOSE=(docker compose -p "$PROJECT" -f docker-compose.yml)
NET="${PROJECT}_aether"
WORKDIR="$(mktemp -d)"

log()  { echo "[e2e] $*"; }
fail() { echo "[e2e] FAIL: $*" >&2; exit 1; }

cleanup() {
  local code=$?
  if [ "$code" -ne 0 ]; then
    echo "[e2e] --- cluster logs (failure) ---" >&2
    "${COMPOSE[@]}" logs 2>&1 | tail -80 >&2
  fi
  "${COMPOSE[@]}" down -v >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# aws-cli container on the cluster network, talking to container <ip>. Endpoint is
# an IP so boto auto-selects path-style addressing. $WORKDIR is mounted at /data.
awsd() {
  local ip=$1; shift
  docker run --rm --network "$NET" \
    -e AWS_ACCESS_KEY_ID=AKIAEXAMPLE -e AWS_SECRET_ACCESS_KEY=devsecret \
    -e AWS_DEFAULT_REGION=us-east-1 -e AWS_EC2_METADATA_DISABLED=true \
    -v "$WORKDIR":/data -w /data amazon/aws-cli \
    "$@" --endpoint-url "http://${ip}:9000"
}

ip_of() {
  docker inspect "${PROJECT}-aether-$1" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
}

log "building + starting 3-node cluster..."
"${COMPOSE[@]}" up --build -d --scale aether=3

log "waiting for 3-node cluster to form..."
formed=0
for i in $(seq 1 120); do
  if docker logs "${PROJECT}-aether-1" 2>&1 | grep -q "cluster membership (3)"; then
    formed=1
    break
  fi
  [ $((i % 10)) -eq 0 ] && log "  ...waiting (${i}/120), running=$("${COMPOSE[@]}" ps -q 2>/dev/null | wc -l | tr -d ' ')"
  sleep 2
done
[ "$formed" = 1 ] || fail "cluster did not form"
log "cluster formed."

IP1="$(ip_of 1)"; IP2="$(ip_of 2)"; IP3="$(ip_of 3)"
[ -n "$IP1" ] && [ -n "$IP2" ] && [ -n "$IP3" ] || fail "could not resolve container IPs"
log "nodes: $IP1 $IP2 $IP3"

# Bucket creation goes through Khepri (CP) — retry until the Raft cluster is ready.
log "creating bucket (node 1)..."
for _ in $(seq 1 30); do
  awsd "$IP1" s3 mb s3://e2e >/dev/null 2>&1 && break
  sleep 1
done
awsd "$IP1" s3api head-bucket --bucket e2e >/dev/null 2>&1 || fail "bucket not created"

# --- small object: write node 1, read node 3 (cross-node) ---
log "PUT small object on node 1, GET from node 3..."
echo "hello aether docker e2e" > "$WORKDIR/small.txt"
awsd "$IP1" s3 cp /data/small.txt s3://e2e/small.txt >/dev/null
awsd "$IP3" s3 cp s3://e2e/small.txt /data/small.out >/dev/null
cmp -s "$WORKDIR/small.txt" "$WORKDIR/small.out" || fail "small object differs across nodes"

# --- concurrent upload (regression: Expect:100-continue keep-alive desync) ---
# aws-cli's recursive transfer reuses connections and sends Expect:100-continue;
# a stale-conn bug used to desync keep-alive connections and 400 ~half of these.
log "concurrent recursive upload (20 objects), expect zero failures..."
mkdir "$WORKDIR/many"
for i in $(seq 0 19); do printf "obj%d" "$i" > "$WORKDIR/many/o$i"; done
fails="$(awsd "$IP1" s3 cp /data/many s3://e2e/many/ --recursive 2>&1 | grep -c failed || true)"
[ "$fails" -eq 0 ] || fail "$fails concurrent uploads failed (keep-alive desync regression)"
listed="$(awsd "$IP3" s3 ls s3://e2e/many/ | grep -c ' o[0-9]' || true)"
[ "$listed" -eq 20 ] || fail "expected 20 objects after concurrent upload, listed $listed"

# --- multipart: 10MB via node 1, read from node 2 ---
log "multipart upload (node 1), GET from node 2, verify..."
head -c 10485760 /dev/urandom > "$WORKDIR/big.bin"
awsd "$IP1" s3 cp /data/big.bin s3://e2e/big.bin >/dev/null
awsd "$IP2" s3 cp s3://e2e/big.bin /data/big.out >/dev/null
cmp -s "$WORKDIR/big.bin" "$WORKDIR/big.out" || fail "multipart object differs across nodes"

etag="$(awsd "$IP3" s3api head-object --bucket e2e --key big.bin --query ETag --output text)"
case "$etag" in
  *-*) log "multipart ETag ok: $etag" ;;
  *)   fail "expected multipart ETag (…-N), got $etag" ;;
esac

# --- delete on node 2, confirm gone from node 3 ---
log "DELETE on node 2, confirm 404 on node 3..."
awsd "$IP2" s3 rm s3://e2e/big.bin >/dev/null
if awsd "$IP3" s3api head-object --bucket e2e --key big.bin >/dev/null 2>&1; then
  fail "object still present after delete"
fi

# --- list from node 3 ---
log "LIST from node 3..."
awsd "$IP3" s3 ls s3://e2e/ | grep -q "small.txt" || fail "list missing small.txt"

log "PASS: docker cluster e2e"

#!/usr/bin/env bash
# End-to-end test: data-plane REBALANCING on topology change. Start 3 nodes (RF=3,
# so every node holds every object), write a batch, then add 2 more nodes and let
# anti-entropy MIGRATE objects to the new HRW owners AND SHED them from nodes that
# are no longer replicas.
#
# Proof: with RF=3, the total number of object copies across the cluster must stay
# at objects×3 — migration alone would balloon it (orphans on old owners), so a
# constant total means the shed pass swept the orphans. We also require the new
# nodes to have received data (migration happened).
#
# Requires: docker (compose). Uses the 5-node stable-name compose. W=1, eviction off.
set -euo pipefail

cd "$(dirname "$0")/../.."

PROJECT="aether-rebal"
COMPOSE=(docker compose -p "$PROJECT" -f docker-compose.static5.yml)
NET="${PROJECT}_aether"
WORKDIR="$(mktemp -d)"
N_OBJ=12
RF=3

log()  { echo "[rebal] $*"; }
fail() { echo "[rebal] FAIL: $*" >&2; exit 1; }

c()     { echo "${PROJECT}-aether$1-1"; }
ip_of() { docker inspect "$(c "$1")" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'; }

cleanup() {
  local code=$?
  if [ "$code" -ne 0 ]; then
    echo "[rebal] --- cluster logs (failure) ---" >&2
    "${COMPOSE[@]}" logs 2>&1 | tail -60 >&2
  fi
  "${COMPOSE[@]}" down -v >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

awsd() {
  local ip=$1; shift
  docker run --rm --network "$NET" \
    -e AWS_ACCESS_KEY_ID=x -e AWS_SECRET_ACCESS_KEY=x \
    -e AWS_DEFAULT_REGION=us-east-1 -e AWS_EC2_METADATA_DISABLED=true \
    -v "$WORKDIR":/data amazon/aws-cli "$@" --endpoint-url "http://${ip}:9000"
}

# Number of object copies this node holds (its local metadata count).
count_on() {
  docker exec -e RELEASE_NODE="aether@aether$1.aethr" "$(c "$1")" /app/bin/aether_s3 \
    rpc 'AetherS3.ObjectMeta.Store.all() |> length() |> IO.puts()' 2>/dev/null | tail -1
}

wait_log() {
  for _ in $(seq 1 "$3"); do
    docker logs "$(c "$1")" 2>&1 | grep -q "$2" && return 0
    sleep 1
  done
  return 1
}

expected=$((N_OBJ * RF))

log "build + start 3 nodes (W=1, RF=$RF)..."
AETHER_WRITE_QUORUM=1 "${COMPOSE[@]}" up --build -d aether1 aether2 aether3 >/dev/null
wait_log 1 "cluster membership (3)" 120 || fail "3-node cluster did not form"
sleep 5
IP1="$(ip_of 1)"

log "create bucket + write $N_OBJ objects..."
for _ in $(seq 1 30); do awsd "$IP1" s3 mb s3://rb >/dev/null 2>&1 && break; sleep 1; done
awsd "$IP1" s3api head-bucket --bucket rb >/dev/null 2>&1 || fail "bucket not created"
mkdir "$WORKDIR/objs"
for i in $(seq 1 "$N_OBJ"); do printf "obj%d" "$i" > "$WORKDIR/objs/k$i"; done
upfails="$(awsd "$IP1" s3 cp /data/objs s3://rb/ --recursive 2>&1 | grep -c failed || true)"
[ "$upfails" -eq 0 ] || fail "$upfails uploads failed"
sleep 3

before=$(( $(count_on 1) + $(count_on 2) + $(count_on 3) ))
log "copies on 3 nodes: $before (expect $expected)"
[ "$before" -eq "$expected" ] || fail "baseline copies $before != $expected"

log "add nodes 4 and 5 — ring reshuffles..."
AETHER_WRITE_QUORUM=1 "${COMPOSE[@]}" up -d aether4 aether5 >/dev/null
wait_log 1 "cluster membership (5)" 60 || fail "did not re-form to 5 nodes"

# Migration first balloons the total (copies on new owners) then the shed pass
# brings it back to objects×RF. Poll until it settles AND the new nodes hold data.
log "waiting for anti-entropy to migrate + shed (converge to $expected copies)..."
converged=0
for _ in $(seq 1 24); do
  n4=$(count_on 4); n5=$(count_on 5)
  total=$(( $(count_on 1) + $(count_on 2) + $(count_on 3) + n4 + n5 ))
  if [ "$total" -eq "$expected" ] && [ "$((n4 + n5))" -gt 0 ]; then
    converged=1
    log "converged: total=$total copies, new nodes n4=$n4 n5=$n5"
    break
  fi
  sleep 5
done

[ "$converged" -eq 1 ] || fail "did not converge: total=$total (expect $expected), n4=$n4 n5=$n5"
log "PASS: rebalancing e2e (copies stayed = objects×RF; new owners filled, orphans shed)"

#!/usr/bin/env bash
# End-to-end BIG-CLUSTER test: form an N-node AetherS3 cluster (default 15) via
# DNSPoll + `--scale`, driven by real aws-cli, and verify at scale:
#
#   1. all N BEAM nodes join AND the Khepri control plane reaches Raft quorum
#      (a bucket create commits) — timed, since both scale with N;
#   2. HRW spreads object replicas across the cluster — each probe key's *holders*
#      (nodes whose metadata store has it) converge to its RingServer.replicas set,
#      RF distinct nodes out of N, and the probes together cover many nodes (not a
#      hot-spot);
#   3. an object written on one node reads back from a far node (cross-node fetch).
#
# NB: every node joins the Khepri Raft cluster, so N=15 is a 15-member Raft
# (quorum 8). This is as much a CONTROL-PLANE-at-scale probe as a data-plane one:
# CP writes commit more slowly than in a 3-node cluster, and formation takes
# longer. It's a strong argument for eventually separating a small CP quorum from
# the data-plane nodes.
#
# Heavy (N BEAM+Khepri containers) — intended as a LOCAL/manual test, not a CI
# gate. Requires: docker (compose). Tunable:
#   N   node count    (default 15)
#   RF  replication   (default 3)
#
#   N=9 RF=3 test/e2e/big_cluster.sh
set -euo pipefail

cd "$(dirname "$0")/../.."

N="${N:-15}"
RF="${RF:-3}"
PROJECT="aether-big"
COMPOSE=(docker compose -p "$PROJECT" -f docker-compose.yml)
NET="${PROJECT}_aether"
WORKDIR="$(mktemp -d)"
PROBES="k1 k2 k3 k4 k5 k6 k7 k8"

log()  { echo "[big] $*"; }
fail() { echo "[big] FAIL: $*" >&2; exit 1; }

cleanup() {
  local code=$?
  if [ "$code" -ne 0 ]; then
    echo "[big] --- cluster logs (failure, tail) ---" >&2
    "${COMPOSE[@]}" logs 2>&1 | tail -100 >&2
  fi
  "${COMPOSE[@]}" down -v >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

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

# rpc on node <n> (self-named aether@<its-ip> under DNSPoll). Uses the cached IP.
rpc_on() {
  docker exec -e RELEASE_NODE="aether@${IPS[$1]}" "${PROJECT}-aether-$1" \
    /app/bin/aether_s3 rpc "$2" 2>/dev/null | tail -1
}

# Wait until container <n>'s logs contain <pattern> (timeout <secs>).
wait_log() {
  for _ in $(seq 1 "$3"); do
    docker logs "${PROJECT}-aether-$1" 2>&1 | grep -q "$2" && return 0
    sleep 1
  done
  return 1
}

sorted_csv() { tr ' ' '\n' | grep . | sort | paste -sd, -; }

# HRW replica node-names for probe/<key>, sorted+comma-joined.
hrw_of() {
  rpc_on 1 "AetherS3.Cluster.RingServer.replicas(\"probe/$1\") |> Enum.join(\" \") |> IO.puts()" | sorted_csv
}

# Cache every node's held keys into KEYS[n] as an inspected list like ["k1","k8"].
refresh_keys() {
  local n
  for n in $(seq 1 "$N"); do
    KEYS[$n]="$(rpc_on "$n" "AetherS3.ObjectMeta.Store.all() |> Enum.map(fn {_, k, _} -> k end) |> inspect() |> IO.puts()")"
  done
}

# Nodes (from the KEYS cache) that hold probe/<key>, sorted+comma-joined. The quoted
# "k1" form in the inspected list avoids prefix false-matches (k1 vs k10).
holders_of() {
  local key="$1" out="" n
  for n in $(seq 1 "$N"); do
    case "${KEYS[$n]}" in *"\"$key\""*) out="$out ${NODE[$n]}" ;; esac
  done
  printf '%s' "$out" | sorted_csv
}

log "building + starting $N-node cluster (RF=$RF, W=1)... this takes a while"
started=$(date +%s)
AETHER_WRITE_QUORUM=1 AETHER_REPLICATION_FACTOR="$RF" \
  "${COMPOSE[@]}" up --build -d --scale aether="$N" >/dev/null

log "waiting for $N BEAM nodes to form the cluster..."
wait_log 1 "cluster membership ($N)" 300 || fail "cluster did not reach $N members"
formed=$(date +%s)
log "BEAM cluster formed with $N members in $((formed - started))s."

# Cache each node's IP + self-name once (docker inspect is slow to call in loops).
declare -a IPS NODE KEYS
for n in $(seq 1 "$N"); do
  IPS[$n]="$(ip_of "$n")"
  NODE[$n]="aether@${IPS[$n]}"
  [ -n "${IPS[$n]}" ] || fail "could not resolve IP for node $n"
done

# CP (Khepri Raft, N members, quorum $(( N/2 + 1 ))) must commit a bucket create.
log "creating bucket — proves the $N-member Raft reached quorum..."
cp_ok=0
for _ in $(seq 1 60); do
  awsd "${IPS[1]}" s3 mb s3://probe >/dev/null 2>&1 && { cp_ok=1; break; }
  sleep 2
done
[ "$cp_ok" = 1 ] || fail "control plane never committed a bucket create (Raft quorum?)"
awsd "${IPS[1]}" s3api head-bucket --bucket probe >/dev/null 2>&1 || fail "bucket not created"
committed=$(date +%s)
log "CP quorum reached; bucket committed $((committed - formed))s after formation."

log "writing ${PROBES// /, } (W=1; anti-entropy then spreads to the RF=$RF replicas)..."
for key in $PROBES; do printf 'value-%s' "$key" > "$WORKDIR/$key"; done
for key in $PROBES; do awsd "${IPS[1]}" s3 cp "/data/$key" "s3://probe/$key" >/dev/null; done

# Cross-node read: written via node 1, fetched from the FARTHEST node.
log "cross-node read: PUT on node 1, GET from node $N..."
awsd "${IPS[$N]}" s3 cp "s3://probe/k1" "/data/k1.out" >/dev/null
cmp -s "$WORKDIR/k1" "$WORKDIR/k1.out" || fail "cross-node read from node $N did not match"

# Snapshot the HRW target for each probe (stable once membership is $N).
for key in $PROBES; do printf -v "HRW_$key" '%s' "$(hrw_of "$key")"; done

log "waiting for holders == HRW (anti-entropy fills all $RF replicas) across $N nodes..."
converged=0
for _ in $(seq 1 30); do
  refresh_keys
  ok=1
  for key in $PROBES; do
    var="HRW_$key"
    [ "$(holders_of "$key")" = "${!var}" ] || { ok=0; break; }
  done
  [ "$ok" -eq 1 ] && { converged=1; break; }
  sleep 5
done

if [ "$converged" -ne 1 ]; then
  for key in $PROBES; do
    var="HRW_$key"
    echo "[big]   $key: holders=$(holders_of "$key")  hrw=${!var}"
  done
  fail "placement did not converge to HRW across $N nodes"
fi

# Each probe must sit on exactly RF distinct nodes...
for key in $PROBES; do
  count=$(holders_of "$key" | tr ',' '\n' | grep -c .)
  [ "$count" -eq "$RF" ] || fail "$key has $count holders, expected RF=$RF"
done

# ...and the probes together must cover many nodes (HRW spreads, not a hot-spot).
spread=$(for key in $PROBES; do hrw_of "$key"; done | tr ',' '\n' | grep . | sort -u | wc -l | tr -d ' ')
log "the $(printf '%s' "$PROBES" | wc -w | tr -d ' ') probes are spread across $spread distinct nodes."
[ "$spread" -gt "$RF" ] || fail "HRW did not spread: only $spread nodes cover all probes (expected > $RF)"

log "PASS: big-cluster e2e [$N nodes, RF=$RF] — CP quorum at scale, HRW spread + anti-entropy verified"

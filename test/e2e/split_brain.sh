#!/usr/bin/env bash
# End-to-end SPLIT-BRAIN test. Proves the two recovery theories on a real cluster,
# driven by a real S3 client (aws-cli):
#
#   Theory 1 (control plane / Raft): during a partition the MAJORITY keeps quorum
#     and serves bucket ops; the MINORITY cannot reach the consistent log (no
#     quorum). On heal the minority resyncs — the majority's bucket appears on it.
#
#   Theory 2 (data plane / AP + LWW): with W=1 both sides accept writes to the same
#     key during the partition; on heal they converge to the last-writer-wins value
#     (the losing write is discarded), surfaced by read-repair.
#
# Partition: an iptables sidecar joins each MINORITY node's network namespace and
# drops all traffic to/from the MAJORITY nodes — so the two sides can't talk, but
# nodes within a side still can, and the S3 client (a different IP) reaches all.
#
# Configurable (defaults = the 3-node CI case: majority {1,2}, minority {3}):
#   SB_COMPOSE   compose file        (default docker-compose.static.yml)
#   SB_PROJECT   compose project     (default aether-split)
#   SB_MAJORITY  majority node nums   (default "1 2")
#   SB_MINORITY  minority node nums   (default "3")
#
# 5-node 3-vs-2 example:
#   SB_COMPOSE=docker-compose.static5.yml SB_PROJECT=aether-split5 \
#   SB_MAJORITY="1 2 3" SB_MINORITY="4 5" test/e2e/split_brain.sh
set -euo pipefail

cd "$(dirname "$0")/../.."

SB_COMPOSE="${SB_COMPOSE:-docker-compose.static.yml}"
PROJECT="${SB_PROJECT:-aether-split}"
read -r -a MAJ <<< "${SB_MAJORITY:-1 2}"
read -r -a MIN <<< "${SB_MINORITY:-3}"
NODES=("${MAJ[@]}" "${MIN[@]}")
N="${#NODES[@]}"

COMPOSE=(docker compose -p "$PROJECT" -f "$SB_COMPOSE")
NET="${PROJECT}_aether"
NETSHOOT="nicolaka/netshoot"
WORKDIR="$(mktemp -d)"

log()  { echo "[split] $*"; }
fail() { echo "[split] FAIL: $*" >&2; exit 1; }

c()     { echo "${PROJECT}-aether$1-1"; }
ip_of() { docker inspect "$(c "$1")" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'; }

cleanup() {
  local code=$?
  heal >/dev/null 2>&1 || true
  if [ "$code" -ne 0 ]; then
    echo "[split] --- cluster logs (failure) ---" >&2
    "${COMPOSE[@]}" logs 2>&1 | tail -80 >&2
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

# Run iptables inside node $1's network namespace (no caps/tools added to our image).
ipt_on() { docker run --rm --network "container:$(c "$1")" --cap-add NET_ADMIN "$NETSHOOT" sh -c "$2"; }

partition() {
  local maj_ips=() j m rule ip
  for j in "${MAJ[@]}"; do maj_ips+=("$(ip_of "$j")"); done
  for m in "${MIN[@]}"; do
    rule=""
    for ip in "${maj_ips[@]}"; do
      rule+="iptables -A INPUT -s $ip -j DROP; iptables -A OUTPUT -d $ip -j DROP; "
    done
    ipt_on "$m" "$rule"
  done
}

heal() { local m; for m in "${MIN[@]}"; do ipt_on "$m" "iptables -F"; done; }

# Wait until container $1's logs contain pattern $2 (timeout $3 secs).
wait_log() {
  local cname="$1" pat="$2" secs="$3"
  for _ in $(seq 1 "$secs"); do
    docker logs "$cname" 2>&1 | grep -q "$pat" && return 0
    sleep 1
  done
  return 1
}

MAJ_NODE="${MAJ[0]}"
MIN_NODE="${MIN[0]}"

log "split: majority {${MAJ[*]}} vs minority {${MIN[*]}} on $N nodes ($SB_COMPOSE)"

# --- bring up: W=1, eviction off -------------------------------------------
log "building + starting $N-node cluster (W=1, eviction off)..."
AETHER_WRITE_QUORUM=1 "${COMPOSE[@]}" up --build -d >/dev/null
wait_log "$(c "$MAJ_NODE")" "cluster membership ($N)" 120 || fail "cluster did not form"
sleep 5
MAJ_IP="$(ip_of "$MAJ_NODE")"; MIN_IP="$(ip_of "$MIN_NODE")"
log "majority entry node=$MAJ_NODE ($MAJ_IP); minority entry node=$MIN_NODE ($MIN_IP)"

# --- baseline (healthy) ----------------------------------------------------
log "baseline: bucket + object, readable across the cluster..."
for _ in $(seq 1 30); do awsd "$MAJ_IP" s3 mb s3://sb >/dev/null 2>&1 && break; sleep 1; done
awsd "$MAJ_IP" s3api head-bucket --bucket sb >/dev/null 2>&1 || fail "baseline bucket not created"
printf 'v0' > "$WORKDIR/v0"
awsd "$MAJ_IP" s3 cp /data/v0 s3://sb/k >/dev/null
awsd "$MIN_IP" s3 cp s3://sb/k /data/v0.out >/dev/null
cmp -s "$WORKDIR/v0" "$WORKDIR/v0.out" || fail "baseline object not readable on the minority side"

# --- PARTITION -------------------------------------------------------------
log "partitioning minority {${MIN[*]}} from majority {${MAJ[*]}} (iptables)..."
partition
log "waiting for the majority to observe the split (net_ticktime ~20s)..."
wait_log "$(c "$MAJ_NODE")" "cluster membership (${#MAJ[@]})" 60 || fail "majority did not observe the partition"

# Theory 1a: majority HAS quorum -> can create a bucket.
log "Theory 1a: majority creates a bucket during the split..."
awsd "$MAJ_IP" s3 mb s3://majonly >/dev/null 2>&1 || fail "majority could not create a bucket"

# Theory 1b: minority has NO quorum -> its bucket-create does not reach the
# consistent log during the split (the majority doesn't see it). The client times
# out; a timed-out command may buffer-commit on heal (consistent Raft behavior),
# so we assert on the majority's mid-split view, not on post-heal absence.
log "Theory 1b: minority write does not commit to the consistent log during the split..."
awsd "$MIN_IP" --cli-connect-timeout 5 --cli-read-timeout 15 s3 mb s3://minonly >/dev/null 2>&1 || true
if awsd "$MAJ_IP" s3api head-bucket --bucket minonly >/dev/null 2>&1; then
  fail "minority's bucket reached the majority during the split (should lack quorum)"
fi

# Theory 2: divergent writes to the SAME key on both sides (W=1).
log "Theory 2: divergent writes (minority then, later, majority -> LWW winner = majority)..."
printf 'vMIN' > "$WORKDIR/vmin"
awsd "$MIN_IP" s3 cp /data/vmin s3://sb/k >/dev/null || fail "minority write failed (W=1 should allow it)"
sleep 2
printf 'vMAJ' > "$WORKDIR/vmaj"
awsd "$MAJ_IP" s3 cp /data/vmaj s3://sb/k >/dev/null || fail "majority write failed"

# --- HEAL ------------------------------------------------------------------
log "healing partition..."
heal
wait_log "$(c "$MAJ_NODE")" "cluster membership ($N)" 60 || fail "cluster did not re-form after heal"
log "waiting for resync + convergence..."

# Theory 1 recovery: the majority's bucket resyncs to the minority. Poll — the CP
# tree resync can lag the raw membership re-forming.
log "Theory 1: majority's bucket 'majonly' visible from the minority side after heal..."
for _ in $(seq 1 40); do
  awsd "$MIN_IP" s3api head-bucket --bucket majonly >/dev/null 2>&1 && break
  sleep 1
done
awsd "$MIN_IP" s3api head-bucket --bucket majonly >/dev/null 2>&1 || fail "minority did not resync the control plane (majonly missing)"

# Theory 2 recovery: key converges to the LWW winner (vMAJ). Poll — read-repair
# needs the inter-node links fully back before the minority serves the majority's
# value; a fixed sleep race here was the test's main flake.
log "Theory 2: key converged to the LWW winner on the minority side..."
got=""
for _ in $(seq 1 40); do
  awsd "$MIN_IP" s3 cp s3://sb/k /data/k.min >/dev/null 2>&1 && got="$(cat "$WORKDIR/k.min")"
  [ "$got" = "vMAJ" ] && break
  sleep 1
done
[ "$got" = "vMAJ" ] || fail "minority side did not converge to LWW winner: got '$got', want 'vMAJ'"
awsd "$MAJ_IP" s3 cp s3://sb/k /data/k.maj >/dev/null
[ "$(cat "$WORKDIR/k.maj")" = "vMAJ" ] || fail "majority side value is not the LWW winner"

log "PASS: split-brain e2e [$N nodes, {${MAJ[*]}} vs {${MIN[*]}}] — CP resynced; data converged via LWW"

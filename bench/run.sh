#!/usr/bin/env bash
# AetherS3 benchmark harness.
#
# Boots a fixed cluster, arms BEAM microstate accounting on every node, drives it
# with `warp` (MinIO's S3 load generator), then collects warp's throughput/latency
# percentiles alongside per-node msacc attribution into one results file.
#
# The point is a data-driven tuning loop: run a stock-args baseline, read the
# msacc breakdown to see what you're bound by, then change ERL_ZFLAGS and re-run.
#
# Usage:
#   ./run.sh                                  # baseline: mixed workload, stock args
#   WORKLOAD=large ./run.sh                   # a different workload
#   ERL_ZFLAGS="+zdbbl 32768" LABEL=zdbbl ./run.sh
#   AUTH=true WORKLOAD=small ./run.sh
#   KEEP=1 ./run.sh                           # leave the cluster up afterwards
#
# Knobs (env vars, with defaults):
#   NODES=3  RF=3  WQ=1  AUTH=false  DURATION=60s  WORKLOAD=mixed
#   ERL_ZFLAGS=""  LABEL=baseline  COOKIE=bench-cluster  KEEP=0
#   IMAGE=wizenink/aether_s3:0.5.0  WARP_IMAGE=minio/warp:latest
set -euo pipefail
cd "$(dirname "$0")"

NODES="${NODES:-3}"
RF="${RF:-3}"
WQ="${WQ:-1}"
AUTH="${AUTH:-false}"
DURATION="${DURATION:-60s}"
WORKLOAD="${WORKLOAD:-mixed}"
ERL_ZFLAGS="${ERL_ZFLAGS:-}"
OBJMETA_SYNC="${OBJMETA_SYNC:-group}"
LABEL="${LABEL:-baseline}"
COOKIE="${COOKIE:-bench-cluster}"
KEEP="${KEEP:-0}"
IMAGE="${IMAGE:-wizenink/aether_s3:0.5.0}"
WARP_IMAGE="${WARP_IMAGE:-minio/warp:latest}"
ELIXIR_IMAGE="${ELIXIR_IMAGE:-elixir:1.20-otp-29-alpine}"
ACCESS_KEY="${ACCESS_KEY:-AKIAEXAMPLE}"
SECRET_KEY="${SECRET_KEY:-devsecret}"

export IMAGE COOKIE AUTH ACCESS_KEY SECRET_KEY WQ RF ERL_ZFLAGS OBJMETA_SYNC

PROJECT="aetherbench"
NET="${PROJECT}_aether"
STATE_DIR="results/.state"
TS="$(date +%Y%m%d-%H%M%S)"
RES="results/${TS}-${WORKLOAD}-${LABEL}.md"

# warp args per workload. Sizes/concurrency chosen to stress different subsystems.
# Per-workload size + a default concurrency; CONCURRENT overrides it (for sweeps).
case "$WORKLOAD" in
  small) OP=mixed;  SIZE="--obj.size 8KiB";  DCONC=40 ;;  # metadata / erpc bound
  large) OP=mixed;  SIZE="--obj.size 16MiB"; DCONC=8  ;;  # streaming / disk / dist bound
  mixed) OP=mixed;  SIZE="--obj.size 1MiB";  DCONC=20 ;;  # balanced
  list)  OP=list;   SIZE="--objects 10000";  DCONC=10 ;;  # list / range-scan bound
  *) echo "unknown WORKLOAD=$WORKLOAD (small|large|mixed|list)"; exit 1 ;;
esac
CONC="${CONCURRENT:-$DCONC}"
WARP_ARGS="$SIZE --concurrent $CONC"

log() { printf '\033[1;36m[bench]\033[0m %s\n' "$*"; }

cleanup() {
  if [ "$KEEP" = "1" ]; then
    log "KEEP=1 — leaving cluster up (tear down: docker compose -p $PROJECT -f compose.bench.yml down -v)"
  else
    log "tearing down cluster"
    docker compose -p "$PROJECT" -f compose.bench.yml down -v >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

curl_net() { docker run --rm --network "$NET" curlimages/curl:latest -s "$@"; }

# --- boot cluster -----------------------------------------------------------
log "starting $NODES-node cluster (RF=$RF WQ=$WQ auth=$AUTH) ERL_ZFLAGS='${ERL_ZFLAGS:-<stock>}'"
docker compose -p "$PROJECT" -f compose.bench.yml up -d --scale aether="$NODES" >/dev/null

log "waiting for cluster to form ($NODES nodes + a leader)"
for i in $(seq 1 90); do
  cj="$(curl_net http://aether:9001/cluster 2>/dev/null || true)"
  if echo "$cj" | grep -q "\"node_count\":$NODES" && echo "$cj" | grep -q '"leader":"aether@'; then
    log "cluster ready after ${i}s"; break
  fi
  [ "$i" = 90 ] && { echo "cluster did not form in time"; echo "$cj"; exit 1; }
  sleep 1
done

# Node IPs -> warp host list (spreads load across all nodes).
IPS="$(echo "$cj" | grep -oE 'aether@[0-9.]+' | sed 's/aether@//' | sort -u)"
HOSTS="$(echo "$IPS" | sed 's/$/:9000/' | paste -sd, -)"
log "warp targets: $HOSTS"

# --- arm collectors, run warp, collect --------------------------------------
rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR" results
OBS="elixir --name observer@\$(hostname -i) --cookie $COOKIE /bench/collect.exs"

log "arming BEAM introspection"
docker run --rm --network "$NET" -v "$PWD":/bench -w /bench "$ELIXIR_IMAGE" \
  sh -c "$OBS start http://aether:9001 /bench/$STATE_DIR"

log "running warp: $OP $WARP_ARGS for $DURATION"
WARP_OUT="$(mktemp)"
set +e
docker run --rm --network "$NET" "$WARP_IMAGE" "$OP" \
  --host "$HOSTS" --access-key "$ACCESS_KEY" --secret-key "$SECRET_KEY" \
  --bucket bench --duration "$DURATION" --noclear $WARP_ARGS 2>&1 | tee "$WARP_OUT"
set -e

log "collecting BEAM introspection"
docker run --rm --network "$NET" -v "$PWD":/bench -w /bench "$ELIXIR_IMAGE" \
  sh -c "$OBS stop http://aether:9001 /bench/$STATE_DIR /bench/results/.collector.md" >/dev/null

# --- assemble results file --------------------------------------------------
{
  echo "# Bench run: $WORKLOAD / $LABEL"
  echo
  echo "- date: $TS"
  echo "- nodes: $NODES   RF: $RF   WQ: $WQ   auth: $AUTH"
  echo "- workload: \`$OP $WARP_ARGS\`   duration: $DURATION"
  echo "- ERL_ZFLAGS: \`${ERL_ZFLAGS:-<stock defaults>}\`"
  echo "- objmeta_sync: $OBJMETA_SYNC"
  echo "- image: $IMAGE"
  echo
  echo "## warp (throughput + latency)"
  echo
  echo '```'
  # Keep the summary section of warp's output (throughput + percentiles).
  grep -vE '^warp: (Preparing|Uploading|Downloading|Benchmarking|Clearing)' "$WARP_OUT" | tail -60
  echo '```'
  echo
  cat results/.collector.md
} > "$RES"
rm -f "$WARP_OUT" results/.collector.md

log "results written: $RES"
echo
sed -n '1,12p' "$RES"

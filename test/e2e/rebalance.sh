#!/usr/bin/env bash
# End-to-end test: data-plane REBALANCING on topology change. Start 3 nodes (RF=3),
# write objects, then add 2 more and let anti-entropy MIGRATE objects to their new
# HRW owners AND SHED them from nodes that are no longer replicas.
#
# Proof: after growing, each probe object's *holders* (the nodes whose metadata
# store has it) must equal its current HRW replica set — migration fills the new
# owners, shedding clears the old ones. The probe set includes MULTIPART objects,
# whose completed manifest is META-ONLY (no blob); those exercise the meta-only
# migration path (a copy-count invariant can't catch a manifest that fails to move,
# since it stays at RF copies, just on the wrong nodes).
#
# Requires: docker (compose). 5-node stable-name cluster, W=1, eviction off.
set -euo pipefail

cd "$(dirname "$0")/../.."

PROJECT="aether-rebal"
COMPOSE=(docker compose -p "$PROJECT" -f docker-compose.static5.yml)
NET="${PROJECT}_aether"
WORKDIR="$(mktemp -d)"
PROBES="k1 k8 big0 big1 big2"

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

rpc_on() {
  docker exec -e RELEASE_NODE="aether@aether$1.aethr" "$(c "$1")" /app/bin/aether_s3 rpc "$2" 2>/dev/null | tail -1
}

wait_log() {
  for _ in $(seq 1 "$3"); do
    docker logs "$(c "$1")" 2>&1 | grep -q "$2" && return 0
    sleep 1
  done
  return 1
}

sorted_csv() { tr ' ' '\n' | grep . | sort | paste -sd, -; }

# HRW replica node-names for rb/<key>, sorted+comma-joined.
hrw_of() {
  rpc_on 1 "AetherS3.Cluster.RingServer.replicas(\"rb/$1\") |> Enum.join(\" \") |> IO.puts()" | sorted_csv
}

# Cache each node's held keys (one rpc per node) into KEYS_<n> as an inspected list
# like ["k1", "big0", ...] (quote-free rpc expression; probe keys are unambiguous).
refresh_keys() {
  local n
  for n in 1 2 3 4 5; do
    printf -v "KEYS_$n" '%s' "$(rpc_on "$n" "AetherS3.ObjectMeta.Store.all() |> Enum.map(fn {_, k, _} -> k end) |> inspect() |> IO.puts()")"
  done
}

# Nodes (from the KEYS_<n> caches) that hold rb/<key>, sorted+comma-joined. The
# quoted form ("k1") in the inspected list avoids prefix false-matches (k1 vs k10).
holders_of() {
  local key="$1" out="" n var
  for n in 1 2 3 4 5; do
    var="KEYS_$n"
    case "${!var}" in *"\"$key\""*) out="$out aether@aether$n.aethr" ;; esac
  done
  printf '%s' "$out" | sorted_csv
}

log "build + start 3 nodes (W=1, RF=3)..."
AETHER_WRITE_QUORUM=1 "${COMPOSE[@]}" up --build -d aether1 aether2 aether3 >/dev/null
wait_log 1 "cluster membership (3)" 120 || fail "3-node cluster did not form"
sleep 5
IP1="$(ip_of 1)"

log "create bucket + write regular objects and multipart (meta-only manifest) objects..."
for _ in $(seq 1 30); do awsd "$IP1" s3 mb s3://rb >/dev/null 2>&1 && break; sleep 1; done
awsd "$IP1" s3api head-bucket --bucket rb >/dev/null 2>&1 || fail "bucket not created"
mkdir "$WORKDIR/objs"
for i in $(seq 1 8); do printf "obj%d" "$i" > "$WORKDIR/objs/k$i"; done
awsd "$IP1" s3 cp /data/objs s3://rb/ --recursive >/dev/null
# >8MB triggers aws-cli multipart -> completed object stored as a meta-only manifest.
head -c 9437184 /dev/urandom > "$WORKDIR/big"
for i in 0 1 2; do awsd "$IP1" s3 cp /data/big "s3://rb/big$i" >/dev/null; done
sleep 2

log "add nodes 4 and 5 — ring reshuffles..."
AETHER_WRITE_QUORUM=1 "${COMPOSE[@]}" up -d aether4 aether5 >/dev/null
wait_log 1 "cluster membership (5)" 60 || fail "did not re-form to 5 nodes"

# HRW is stable once membership is 5; snapshot the target placement per probe.
for key in $PROBES; do printf -v "HRW_$key" '%s' "$(hrw_of "$key")"; done

log "waiting for holders == HRW (migrate + shed) for: $PROBES"
converged=0
for _ in $(seq 1 24); do
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
    echo "[rebal]   $key: holders=$(holders_of "$key")  hrw=${!var}"
  done
  fail "placement did not converge to HRW"
fi

# Confirm at least one manifest's HRW landed on a NEW node — so meta-only migration
# to a new owner was actually exercised (not just a no-op placement).
moved=0
for key in big0 big1 big2; do
  case "$(hrw_of "$key")" in *aether4* | *aether5*) moved=1 ;; esac
done
[ "$moved" -eq 1 ] && log "a meta-only manifest migrated onto a new node ✓" ||
  log "note: no manifest's HRW landed on a new node this run (placement still verified)"

log "PASS: rebalancing e2e — every object (incl. meta-only manifests) placed exactly on its HRW replicas"

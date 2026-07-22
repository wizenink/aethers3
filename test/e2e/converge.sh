#!/usr/bin/env bash
# End-to-end test: anti-entropy CONVERGENCE on a node KILL-then-RETURN.
#
# rebalance.sh only covers GROWING a cluster (3->5). This covers the harder case
# the shed path actually exists for: a replica LEAVES, a temp owner fills in to
# restore RF, then the replica RETURNS and that temp owner must SHED its now-extra
# copy so the object settles back to exactly RF copies on its original HRW owners.
#
# Proof, for every probe object the killed node was a replica of:
#   1. after KILL   -> holders == the (4-node) HRW set, i.e. RF restored among the
#                      LIVE nodes via a NEW temp owner (repair kept RF durable), and
#   2. after RETURN -> holders == the ORIGINAL (5-node) HRW set exactly, within a
#                      bounded wait (temp owner shed, returned node's copy counted).
#
# A failure in (2) is the candidate bug David observed as transient extra copies on
# a real cluster: the temp owner never sheds (e.g. returned node has the blob but is
# missing the ObjectMeta entry, so safely_replicated? sees it absent). A pass proves
# those extra copies were just reconcile lag and the cluster does re-settle to RF.
#
# Requires: docker (compose). 5-node stable-name cluster, RF=3, W=1, eviction off.
# The killed node keeps its named volume across stop/start, so it returns WITH its
# data (a clean SIGTERM stop -> graceful drain -> metadata is flushed).
set -euo pipefail

cd "$(dirname "$0")/../.."

PROJECT="aether-converge"
COMPOSE=(docker compose -p "$PROJECT" -f docker-compose.static5.yml)
NET="${PROJECT}_aether"
WORKDIR="$(mktemp -d)"
VICTIM=3
VICTIM_NODE="aether@aether${VICTIM}.aethr"
PROBES="k1 k2 k3 k4 k5 k6 k7 k8 k9 k10"

log()  { echo "[converge] $*"; }
fail() { echo "[converge] FAIL: $*" >&2; exit 1; }

c()     { echo "${PROJECT}-aether$1-1"; }
ip_of() { docker inspect "$(c "$1")" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'; }

cleanup() {
  local code=$?
  if [ "$code" -ne 0 ]; then
    echo "[converge] --- cluster logs (failure) ---" >&2
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

# rpc against node $1. Query nodes should be UP; a down node returns empty.
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

# Live cluster size as seen by node1 (persistent_term membership, event-driven on
# nodeup/nodedown). Used to gate on the kill (5->4) and the return (4->5).
members() { rpc_on 1 "IO.puts(length([Node.self() | Node.list()]))"; }
wait_members() {
  for _ in $(seq 1 "$2"); do
    [ "$(members)" = "$1" ] && return 0
    sleep 2
  done
  return 1
}

sorted_csv() { tr ' ' '\n' | grep . | sort | paste -sd, -; }

# HRW replica node-names for rb/<key> under the CURRENT membership, sorted+joined.
hrw_of() {
  rpc_on 1 "AetherS3.Cluster.RingServer.replicas(\"rb/$1\") |> Enum.join(\" \") |> IO.puts()" | sorted_csv
}

# Cache each live node's held keys (one rpc/node) into KEYS_<n> as an inspected
# list. A down node's rpc yields "", so it contributes no holders — exactly right.
refresh_keys() {
  local n
  for n in 1 2 3 4 5; do
    printf -v "KEYS_$n" '%s' "$(rpc_on "$n" "AetherS3.ObjectMeta.Store.all() |> Enum.map(fn {_, k, _} -> k end) |> inspect() |> IO.puts()")"
  done
}

# Nodes (from the KEYS_<n> caches) that hold rb/<key>, sorted+joined. The quoted
# form ("k1") in the inspected list avoids prefix false-matches (k1 vs k10).
holders_of() {
  local key="$1" out="" n var
  for n in 1 2 3 4 5; do
    var="KEYS_$n"
    case "${!var}" in *"\"$key\""*) out="$out aether@aether$n.aethr" ;; esac
  done
  printf '%s' "$out" | sorted_csv
}

dump_victims() {
  local key var
  for key in $VICTIMS; do
    var="$1_$key"
    echo "[converge]   $key: holders=$(holders_of "$key")  want=${!var}"
  done
}

log "build + start 5 nodes (RF=3, W=1, eviction off)..."
AETHER_WRITE_QUORUM=1 "${COMPOSE[@]}" up --build -d >/dev/null
wait_log 1 "cluster membership (5)" 150 || fail "5-node cluster did not form"
sleep 5
IP1="$(ip_of 1)"

log "create bucket + write ${PROBES// /, } ..."
for _ in $(seq 1 30); do awsd "$IP1" s3 mb s3://rb >/dev/null 2>&1 && break; sleep 1; done
awsd "$IP1" s3api head-bucket --bucket rb >/dev/null 2>&1 || fail "bucket not created"
mkdir "$WORKDIR/objs"
for key in $PROBES; do printf "payload-%s" "$key" > "$WORKDIR/objs/$key"; done
awsd "$IP1" s3 cp /data/objs s3://rb/ --recursive >/dev/null
sleep 2

# Snapshot the original (5-node) placement, then pick the probes the victim owns —
# those are the ones a temp owner must cover on kill and shed on return.
for key in $PROBES; do printf -v "ORIG_$key" '%s' "$(hrw_of "$key")"; done
VICTIMS=""
for key in $PROBES; do
  var="ORIG_$key"
  case ",${!var}," in *",$VICTIM_NODE,"*) VICTIMS="$VICTIMS $key" ;; esac
done
VICTIMS="${VICTIMS# }"
n_victims=$(echo "$VICTIMS" | wc -w | tr -d ' ')
[ "$n_victims" -ge 2 ] || fail "victim node owns only $n_victims probe(s); need >= 2 (rerun; HRW placement varies)"
log "node $VICTIM is a replica for: $VICTIMS"

# --- KILL: victim leaves, temp owner must restore RF among the live nodes ---
log "stop node $VICTIM (clean SIGTERM; volume kept)..."
docker stop "$(c "$VICTIM")" >/dev/null
wait_members 4 40 || fail "cluster did not drop to 4 members after kill"

# Target placement while down is the 4-node HRW; require it to actually differ from
# the original for every victim (a temp owner appears) — else there's nothing to shed.
for key in $VICTIMS; do printf -v "DOWN_$key" '%s' "$(hrw_of "$key")"; done
for key in $VICTIMS; do
  o="ORIG_$key"; d="DOWN_$key"
  [ "${!o}" != "${!d}" ] || fail "placement for $key unchanged after kill (no temp owner to test shed)"
  case ",${!d}," in *",$VICTIM_NODE,"*) fail "down-HRW for $key still lists the killed node" ;; esac
done

log "waiting for holders == 4-node HRW (temp owner fills in) ..."
converged=0
for _ in $(seq 1 24); do
  refresh_keys
  ok=1
  for key in $VICTIMS; do
    d="DOWN_$key"
    [ "$(holders_of "$key")" = "${!d}" ] || { ok=0; break; }
  done
  [ "$ok" -eq 1 ] && { converged=1; break; }
  sleep 5
done
[ "$converged" -eq 1 ] || { dump_victims DOWN; fail "RF not restored to temp owners after kill"; }
log "RF restored: temp owner(s) filled in for the killed replica ✓"

# --- RETURN: victim comes back, temp owner must SHED, placement reverts to original ---
log "start node $VICTIM; wait for it to rejoin (5 members)..."
docker start "$(c "$VICTIM")" >/dev/null
wait_members 5 60 || fail "node did not rejoin (5 members)"
# RingServer on the surviving nodes must see 5 again before HRW reverts. Gate on the
# original HRW for a victim listing the returned node once more.
first_victim="${VICTIMS%% *}"
for _ in $(seq 1 30); do
  case ",$(hrw_of "$first_victim")," in *",$VICTIM_NODE,"*) break ;; esac
  sleep 2
done

log "waiting for holders to converge back to the ORIGINAL HRW set (temp owner sheds) ..."
converged=0
for _ in $(seq 1 36); do
  refresh_keys
  ok=1
  for key in $VICTIMS; do
    o="ORIG_$key"
    [ "$(holders_of "$key")" = "${!o}" ] || { ok=0; break; }
  done
  [ "$ok" -eq 1 ] && { converged=1; break; }
  sleep 5
done
[ "$converged" -eq 1 ] || { dump_victims ORIG; fail "did not converge back to RF on original owners (temp-owner shed lagging or broken)"; }

log "PASS: kill-then-return converged back to exactly RF copies on the original HRW owners"

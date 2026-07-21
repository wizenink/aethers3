#!/usr/bin/env bash
# End-to-end test: real S3 traffic under concurrency, driven by warp (MinIO's S3
# load/correctness tool). warp isn't just a benchmark — it VERIFIES every read
# (object size + etag on GET/STAT), so a run that finishes with zero errors is a
# real proof that concurrent PUT/GET/STAT/DELETE round-trips are correct across
# the cluster. (This is exactly the check that would have caught the aws-chunked
# 0-byte bug.)
#
# Boots the 3-node stable-name cluster, runs a mixed warp workload against all
# three nodes, and asserts warp reported no errors.
#
# Requires: docker (compose). The minio/warp image is pulled at runtime.
set -euo pipefail

cd "$(dirname "$0")/../.."

PROJECT="aether-warp"
COMPOSE=(docker compose -p "$PROJECT" -f docker-compose.static.yml)
NET="${PROJECT}_aether"
OUT="$(mktemp)"

log()  { echo "[warp] $*"; }
fail() { echo "[warp] FAIL: $*" >&2; exit 1; }

c()     { echo "${PROJECT}-aether$1-1"; }
ip_of() { docker inspect "$(c "$1")" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'; }

cleanup() {
  local code=$?
  if [ "$code" -ne 0 ]; then
    echo "[warp] --- cluster logs (failure) ---" >&2
    "${COMPOSE[@]}" logs 2>&1 | tail -80 >&2
  fi
  "${COMPOSE[@]}" down -v >/dev/null 2>&1 || true
  rm -f "$OUT"
  exit "$code"
}
trap cleanup EXIT

wait_log() {
  for _ in $(seq 1 "$3"); do
    docker logs "$(c "$1")" 2>&1 | grep -q "$2" && return 0
    sleep 1
  done
  return 1
}

log "build + start 3-node cluster..."
"${COMPOSE[@]}" up -d --build

wait_log 1 "cluster membership (3)" 120 || fail "3-node cluster did not form"
sleep 5

HOSTS="$(ip_of 1):9000,$(ip_of 2):9000,$(ip_of 3):9000"
log "warp targets: $HOSTS"

# Mixed workload (GET/STAT/PUT/DELETE) across all nodes, then warp's end-of-run
# cleanup — which lists the bucket and bulk-deletes via DeleteObjects, so this run
# also exercises multi-object delete + LIST pagination under a real workload. Auth
# is off in this compose, so the creds are ignored (warp always signs).
log "running warp mixed (1 MiB objects, 20 concurrent, 20s) + cleanup..."
docker run --rm --network "$NET" minio/warp:latest mixed \
  --host "$HOSTS" \
  --access-key AKIAEXAMPLE --secret-key devsecret \
  --bucket warp-e2e --obj.size 1MiB --concurrent 20 --duration 20s \
  >"$OUT" 2>&1 || fail "warp exited non-zero"

grep -q "Report: Total" "$OUT" || { cat "$OUT" >&2; fail "warp produced no report — did it run?"; }

# warp logs verification failures as "warp: <ERROR>" / "unexpected <op> size", and
# the report shows a non-zero "Errors:" tally. Any of these means a lost/corrupt
# object or a protocol bug.
if grep -qiE "warp: <ERROR>|unexpected .*size|Errors: [1-9]" "$OUT"; then
  echo "[warp] --- warp errors ---" >&2
  grep -iE "ERROR|unexpected|errors" "$OUT" | head -20 >&2
  fail "warp reported errors — objects were lost/corrupted or a protocol regressed"
fi

# Sanity: the run actually moved data.
grep -A2 "Report: Total" "$OUT" | grep -E "obj/s" | head -1

log "PASS: concurrent warp workload round-tripped with zero errors"

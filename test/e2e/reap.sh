#!/usr/bin/env bash
# End-to-end test: incomplete-multipart-upload REAPING. Start a multipart upload,
# upload a part, but never Complete or Abort it — so an `_init` marker + part
# objects linger under the reserved __mpu__ bucket. The reaper sweeps any upload
# whose marker has outlived the grace, deleting its parts + marker cluster-wide.
#
# Proof, driven directly via `Coordinator.reap_incomplete_uploads/1` (deterministic,
# no waiting on the 60s timer):
#   1. reap with a LARGE grace (1h) leaves the fresh, in-flight upload untouched
#      — the age grace is what protects uploads still in progress.
#   2. reap with grace 0 sweeps it — every __mpu__ key for that upload is gone.
#
# Requires: docker (compose). 3-node stable-name cluster, W=1.
set -euo pipefail

cd "$(dirname "$0")/../.."

PROJECT="aether-reap"
COMPOSE=(docker compose -p "$PROJECT" -f docker-compose.static.yml)
NET="${PROJECT}_aether"
WORKDIR="$(mktemp -d)"

log()  { echo "[reap] $*"; }
fail() { echo "[reap] FAIL: $*" >&2; exit 1; }

c()     { echo "${PROJECT}-aether$1-1"; }
ip_of() { docker inspect "$(c "$1")" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'; }

cleanup() {
  local code=$?
  if [ "$code" -ne 0 ]; then
    echo "[reap] --- cluster logs (failure) ---" >&2
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

# All keys currently under the reserved __mpu__ bucket, cluster-wide.
mpu_keys() {
  rpc_on 1 'AetherS3.Replication.Coordinator.list(AetherS3.Storage.Multipart.bucket()) |> Enum.map(fn {k, _} -> k end) |> inspect() |> IO.puts()'
}

# Does any __mpu__ key belong to upload <id>?  (keys are "<id>/_init", "<id>/1", ...)
has_upload() { case "$(mpu_keys)" in *"\"$1/"*) return 0 ;; *) return 1 ;; esac; }

log "build + start 3 nodes (W=1)..."
AETHER_WRITE_QUORUM=1 "${COMPOSE[@]}" up --build -d >/dev/null
wait_log 1 "cluster membership (3)" 120 || fail "3-node cluster did not form"
sleep 5
IP1="$(ip_of 1)"

log "create bucket..."
for _ in $(seq 1 30); do awsd "$IP1" s3 mb s3://rp >/dev/null 2>&1 && break; sleep 1; done
awsd "$IP1" s3api head-bucket --bucket rp >/dev/null 2>&1 || fail "bucket not created"

log "start a multipart upload + one part, but never complete it..."
UPLOAD_ID="$(awsd "$IP1" s3api create-multipart-upload --bucket rp --key abandoned \
  --query UploadId --output text)"
[ -n "$UPLOAD_ID" ] || fail "no UploadId returned"
log "  upload id: $UPLOAD_ID"
head -c 6291456 /dev/urandom > "$WORKDIR/part1"   # 6MB (>5MB min part)
awsd "$IP1" s3api upload-part --bucket rp --key abandoned --part-number 1 \
  --upload-id "$UPLOAD_ID" --body /data/part1 >/dev/null

has_upload "$UPLOAD_ID" || fail "upload's __mpu__ objects not present after upload-part"
log "  parts + marker present under __mpu__ ✓"

# 1. Age grace protects an in-flight upload: reap with a 1h grace must be a no-op.
log "reap with a 1h grace — the fresh upload must survive..."
reaped="$(rpc_on 1 'AetherS3.Replication.Coordinator.reap_incomplete_uploads(3_600_000) |> IO.puts()')"
[ "$reaped" = "0" ] || fail "1h-grace reap swept $reaped upload(s); should protect fresh uploads"
has_upload "$UPLOAD_ID" || fail "fresh upload was wrongly reaped under a 1h grace"
log "  fresh upload untouched ✓"

# 2. grace 0 reaps it: marker + parts gone cluster-wide.
log "reap with grace 0 — the abandoned upload must be swept..."
reaped="$(rpc_on 1 'AetherS3.Replication.Coordinator.reap_incomplete_uploads(0) |> IO.puts()')"
[ "$reaped" = "1" ] || fail "grace-0 reap swept $reaped upload(s), expected 1"
sleep 1
has_upload "$UPLOAD_ID" && fail "upload's __mpu__ objects still present after reap"
log "  abandoned upload swept (parts + marker gone) ✓"

log "PASS: incomplete-multipart-upload reaping e2e"

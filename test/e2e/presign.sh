#!/usr/bin/env bash
# End-to-end test: presigned URLs. One AetherS3 node with auth ON. A real S3
# client (aws-cli) mints a presigned URL; curl fetches it with NO credentials,
# and an unsigned request is rejected — exercising query-string SigV4 and the
# real Host-header binding the unit tests can't reach (Plug.Test has no host).
#
# Requires: elixir/mix, aws-cli, curl on PATH.
set -euo pipefail

cd "$(dirname "$0")/../.."

PORT=9000
ADMIN_PORT=9001
WORKDIR="$(mktemp -d)"
PID=""

export AWS_ACCESS_KEY_ID=AKIAEXAMPLE AWS_SECRET_ACCESS_KEY=devsecret
export AWS_DEFAULT_REGION=us-east-1 AWS_EC2_METADATA_DISABLED=true

log() { echo "[e2e] $*"; }
fail() { echo "[e2e] FAIL: $*" >&2; exit 1; }

cleanup() {
  local code=$?
  [ "$code" -ne 0 ] && tail -30 "$WORKDIR/node.log" 2>/dev/null >&2
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

aws_() { aws --endpoint-url "http://127.0.0.1:$PORT" "$@"; }
code_of() { curl -s -o /dev/null -w '%{http_code}' "$1"; }

log "compiling..."
mix deps.get >/dev/null
mix compile >/dev/null

log "starting a single node with auth ON..."
AETHER_PORT=$PORT AETHER_ADMIN_PORT=$ADMIN_PORT \
  AETHER_DATA_DIR="$WORKDIR/data" AETHER_REQUIRE_AUTH=true AETHER_REPLICATION_FACTOR=1 \
  elixir -S mix run --no-halt >"$WORKDIR/node.log" 2>&1 &
PID=$!

log "waiting for readiness..."
for _ in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:$ADMIN_PORT/ready" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$ADMIN_PORT/ready" >/dev/null 2>&1 || fail "node not ready"

log "creating bucket + object (signed, as root)..."
for _ in $(seq 1 30); do aws_ s3 mb s3://presign >/dev/null 2>&1 && break; sleep 1; done
echo "hello presigned world" >"$WORKDIR/o.txt"
aws_ s3 cp "$WORKDIR/o.txt" s3://presign/o.txt >/dev/null || fail "object PUT failed"

log "an unsigned GET is rejected (auth is on)..."
code=$(code_of "http://127.0.0.1:$PORT/presign/o.txt")
[ "$code" = "403" ] || fail "expected 403 for unsigned GET, got $code"

log "presign a GET and fetch it with NO credentials..."
url=$(aws_ s3 presign s3://presign/o.txt --expires-in 300)
curl -fsS "$url" -o "$WORKDIR/out.txt" || fail "presigned GET failed"
cmp -s "$WORKDIR/o.txt" "$WORKDIR/out.txt" || fail "presigned GET content differs"

log "a tampered presigned URL is rejected..."
last="${url: -1}"
if [ "$last" = "0" ]; then repl=1; else repl=0; fi
code=$(code_of "${url%?}$repl")
[ "$code" = "403" ] || fail "expected 403 for tampered presigned URL, got $code"

log "PASS: presigned URL e2e"

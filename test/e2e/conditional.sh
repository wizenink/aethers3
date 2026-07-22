#!/usr/bin/env bash
# End-to-end test: conditional requests (RFC 9110 preconditions) over the wire.
# One AetherS3 node with auth OFF, driven by curl so the assertions are exact HTTP
# status codes — 304 with a genuinely empty body, 412, 404 — which Plug.Test can
# only approximate. A real S3 client (aws-cli) then exercises create-if-absent to
# prove SDK compatibility, not just hand-rolled headers.
#
# Covers reads (If-Match / If-None-Match / If-Modified-Since / If-Unmodified-Since)
# and writes (If-None-Match: * create-if-absent, If-Match compare-and-swap),
# including that a refused write leaves the stored object untouched.
#
# Requires: elixir/mix, aws-cli, curl on PATH.
set -euo pipefail

cd "$(dirname "$0")/../.."

PORT=9000
ADMIN_PORT=9001
WORKDIR="$(mktemp -d)"
PID=""
BUCKET="cond"

export AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=x
export AWS_DEFAULT_REGION=us-east-1 AWS_EC2_METADATA_DISABLED=true

log()  { echo "[cond] $*"; }
fail() { echo "[cond] FAIL: $*" >&2; exit 1; }

cleanup() {
  local code=$?
  [ "$code" -ne 0 ] && tail -30 "$WORKDIR/node.log" 2>/dev/null >&2
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

aws_() { aws --endpoint-url "http://127.0.0.1:$PORT" "$@"; }
url()  { echo "http://127.0.0.1:$PORT/$BUCKET/$1"; }

# Status code for a GET/HEAD/PUT carrying one extra request header.
get_code()  { curl -s -o /dev/null -w '%{http_code}' -H "$2" "$(url "$1")"; }
head_code() { curl -s -o /dev/null -w '%{http_code}' -I -H "$2" "$(url "$1")"; }
put_code()  { curl -s -o /dev/null -w '%{http_code}' -X PUT --data-binary "$3" -H "$2" "$(url "$1")"; }
body_of()   { curl -s "$(url "$1")"; }

# The object's current etag, unquoted, read from a plain GET's response headers —
# a client must be able to get a validator from the read itself, without a HEAD.
etag_of() {
  curl -s -D - -o /dev/null "$(url "$1")" |
    tr -d '\r' | awk 'tolower($1) == "etag:" { gsub(/"/, "", $2); print $2 }'
}

# An HTTP-date offset from now by $1 seconds. GNU date uses -d @epoch, BSD -r epoch.
# LC_ALL=C is required: an HTTP-date's day/month names are English by spec, and a
# localized shell would otherwise emit e.g. "mié., 22 jul. 2026".
http_date_offset() {
  local at=$(( $(date +%s) + $1 ))
  if LC_ALL=C date -u -d "@$at" '+%a, %d %b %Y %H:%M:%S GMT' 2>/dev/null; then :; else
    LC_ALL=C date -u -r "$at" '+%a, %d %b %Y %H:%M:%S GMT'
  fi
}

expect() { # expect <what> <got> <want>
  [ "$2" = "$3" ] || fail "$1: expected $3, got $2"
}

log "compiling..."
mix deps.get >/dev/null
mix compile >/dev/null

log "starting a single node (auth off, RF=1)..."
AETHER_PORT=$PORT AETHER_ADMIN_PORT=$ADMIN_PORT \
  AETHER_DATA_DIR="$WORKDIR/data" AETHER_REQUIRE_AUTH=false AETHER_REPLICATION_FACTOR=1 \
  elixir -S mix run --no-halt >"$WORKDIR/node.log" 2>&1 &
PID=$!

log "waiting for readiness..."
for _ in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:$ADMIN_PORT/ready/cp" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$ADMIN_PORT/ready/cp" >/dev/null 2>&1 || fail "node not ready"

log "creating bucket + object..."
for _ in $(seq 1 30); do aws_ s3 mb "s3://$BUCKET" >/dev/null 2>&1 && break; sleep 1; done
printf 'v1' >"$WORKDIR/o.txt"
aws_ s3 cp "$WORKDIR/o.txt" "s3://$BUCKET/o.txt" >/dev/null || fail "object PUT failed"
ETAG="$(etag_of o.txt)"
[ -n "$ETAG" ] || fail "could not read the object's etag"

# --- conditional READS -------------------------------------------------------

log "GET If-None-Match matching -> 304 with an empty body..."
expect "if-none-match match" "$(get_code o.txt "If-None-Match: \"$ETAG\"")" 304
out="$(curl -s -H "If-None-Match: \"$ETAG\"" "$(url o.txt)")"
[ -z "$out" ] || fail "304 response carried a body: $out"

log "GET If-None-Match stale -> 200 with the object..."
expect "if-none-match stale" "$(get_code o.txt 'If-None-Match: "stale"')" 200

log "GET If-None-Match: * on an existing object -> 304..."
expect "if-none-match star" "$(get_code o.txt 'If-None-Match: *')" 304

log "GET If-Match matching -> 200; non-matching -> 412..."
expect "if-match match"    "$(get_code o.txt "If-Match: \"$ETAG\"")" 200
expect "if-match mismatch" "$(get_code o.txt 'If-Match: "nope"')" 412

log "HEAD honors preconditions too..."
expect "head if-none-match" "$(head_code o.txt "If-None-Match: \"$ETAG\"")" 304
expect "head if-match"      "$(head_code o.txt 'If-Match: "nope"')" 412

log "GET date conditionals..."
PAST="$(http_date_offset -3600)"
FUTURE="$(http_date_offset 3600)"
# Not modified since a future instant -> 304; modified since an hour ago -> 200.
expect "if-modified-since future"  "$(get_code o.txt "If-Modified-Since: $FUTURE")" 304
expect "if-modified-since past"    "$(get_code o.txt "If-Modified-Since: $PAST")" 200
# Unchanged since a future instant -> 200; changed since an hour ago -> 412.
expect "if-unmodified-since future" "$(get_code o.txt "If-Unmodified-Since: $FUTURE")" 200
expect "if-unmodified-since past"   "$(get_code o.txt "If-Unmodified-Since: $PAST")" 412

log "an unparseable date is ignored, not an error (RFC 9110)..."
expect "garbage date" "$(get_code o.txt 'If-Modified-Since: not-a-date')" 200

# --- conditional WRITES ------------------------------------------------------

log "PUT If-None-Match: * creates an absent key..."
expect "create-if-absent" "$(put_code new.txt 'If-None-Match: *' 'created')" 200
expect "created content" "$(body_of new.txt)" "created"

log "PUT If-None-Match: * is refused once the key exists, and does not overwrite..."
expect "create-if-absent refused" "$(put_code new.txt 'If-None-Match: *' 'clobbered')" 412
expect "content preserved" "$(body_of new.txt)" "created"

log "PUT If-Match with the current etag swaps the content (CAS)..."
expect "cas ok" "$(put_code o.txt "If-Match: \"$ETAG\"" 'v2')" 200
expect "cas content" "$(body_of o.txt)" "v2"

log "PUT If-Match with a stale etag is refused and leaves the object alone..."
# $ETAG is now stale — the CAS above replaced the object.
expect "cas stale" "$(put_code o.txt "If-Match: \"$ETAG\"" 'v3')" 412
expect "cas content preserved" "$(body_of o.txt)" "v2"

log "PUT If-Match on a missing key -> 404..."
expect "cas missing" "$(put_code ghost.txt 'If-Match: "whatever"' 'x')" 404

# --- real S3 client ----------------------------------------------------------

# Proves an actual SDK's conditional write is honored, not just curl-built headers.
# --if-none-match landed in recent aws-cli v2; if this build predates it the first
# call fails and we skip rather than fail CI on a client-version difference.
log "aws-cli create-if-absent..."
if aws_ s3api put-object --bucket "$BUCKET" --key sdk.txt \
     --body "$WORKDIR/o.txt" --if-none-match '*' >/dev/null 2>&1; then
  if aws_ s3api put-object --bucket "$BUCKET" --key sdk.txt \
       --body "$WORKDIR/o.txt" --if-none-match '*' >/dev/null 2>&1; then
    fail "aws-cli If-None-Match: * overwrote an existing key"
  fi
  log "aws-cli honors If-None-Match: * (create-if-absent) ✓"
else
  log "note: this aws-cli has no --if-none-match on put-object; skipped the SDK check"
fi

log "PASS: conditional requests — reads (304/412) and writes (create-if-absent, CAS) over the wire"

#!/usr/bin/env bash
# Random S3 load generator for an AetherS3 cluster.
#
# Spreads a stream of random operations — create bucket, upload random file, get,
# copy, move, delete, list — across the nodes you give it. Handy for watching a
# cluster work (the console viz, logs, or /metrics) instead of a still picture.
#
# Usage:
#   scripts/load.sh http://node1:9000 http://node2:9000 http://node3:9000
#   scripts/load.sh 192.168.97.5 192.168.97.6      # bare host -> :9000
#   COUNT=300 SLEEP=0.1 PARALLEL=4 scripts/load.sh 192.168.97.5
#
# Env:
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY   creds (default AKIAEXAMPLE / devsecret)
#   SLEEP     seconds between ops, per worker    (default 0.3)
#   COUNT     ops per worker; 0 = run forever    (default 0)
#   PARALLEL  concurrent workers                 (default 1)
#   MAXOBJS   soft cap on tracked objects/worker (default 200)
#
# Requires aws-cli on PATH. Ctrl-C to stop. It leaves the data it created (that's
# the point — a populated cluster); clean up later with, e.g.:
#   for b in $(aws --endpoint-url http://node:9000 s3 ls | awk '{print $3}' | grep '^load-'); do
#     aws --endpoint-url http://node:9000 s3 rb "s3://$b" --force; done
set -uo pipefail

command -v aws >/dev/null || { echo "aws-cli not found on PATH" >&2; exit 1; }

SLEEP="${SLEEP:-0.3}"
COUNT="${COUNT:-0}"
PARALLEL="${PARALLEL:-1}"
MAXOBJS="${MAXOBJS:-200}"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-AKIAEXAMPLE}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-devsecret}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_EC2_METADATA_DISABLED=true

# ── normalize endpoints (add http:// and :9000 where missing) ──
ENDPOINTS=()
for a in "$@"; do
  u="$a"
  case "$u" in http://* | https://*) ;; *) u="http://$u" ;; esac
  hostport="${u#*://}"
  case "$hostport" in *:[0-9]*) ;; *) u="${u}:9000" ;; esac
  ENDPOINTS+=("$u")
done
[ "${#ENDPOINTS[@]}" -eq 0 ] && ENDPOINTS=("http://localhost:9000")

rand_node() { echo "${ENDPOINTS[$((RANDOM % ${#ENDPOINTS[@]}))]}"; }
awsx() { aws --endpoint-url "$(rand_node)" --cli-connect-timeout 5 --cli-read-timeout 30 "$@"; }
rand_str() { printf '%04x%04x' "$RANDOM" "$RANDOM"; }
# mostly small, ~1 in 7 big enough (>8MB) to trigger client-side multipart
rand_size() {
  if [ $((RANDOM % 7)) -eq 0 ]; then echo $((8 * 1024 * 1024 + RANDOM * 512)); else echo $((256 + RANDOM * 8)); fi
}
now() { date +%H:%M:%S; }
log() { printf '%s [w%s] %-4s %s\n' "$(now)" "$1" "$2" "$3"; }

worker() {
  local id="$1" i=0 op sub b k nk sz idx entry
  local buckets=() objects=()
  local tmp; tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN

  while :; do
    i=$((i + 1))
    [ "$COUNT" -gt 0 ] && [ "$i" -gt "$COUNT" ] && break
    op=$((RANDOM % 100))

    if [ "${#buckets[@]}" -eq 0 ] || [ "$op" -lt 6 ]; then
      # ── create a bucket ──
      b="load-${id}-$(rand_str)"
      if awsx s3 mb "s3://$b" >/dev/null 2>&1; then buckets+=("$b"); log "$id" mb "$b"; fi

    elif [ "$op" -lt 58 ] || [ "${#objects[@]}" -eq 0 ]; then
      # ── upload a random file ──
      b="${buckets[$((RANDOM % ${#buckets[@]}))]}"
      k="obj-$(rand_str)"
      sz="$(rand_size)"
      head -c "$sz" /dev/urandom > "$tmp"
      if awsx s3 cp "$tmp" "s3://$b/$k" >/dev/null 2>&1; then
        objects+=("$b|$k"); log "$id" put "$b/$k (${sz}B)"
      fi
      [ "${#objects[@]}" -gt "$MAXOBJS" ] && objects=("${objects[@]:1}")

    else
      # ── operate on an existing object ──
      idx=$((RANDOM % ${#objects[@]}))
      entry="${objects[$idx]}"; b="${entry%%|*}"; k="${entry#*|}"
      sub=$((RANDOM % 100))
      if [ "$sub" -lt 34 ]; then
        awsx s3 cp "s3://$b/$k" - >/dev/null 2>&1 && log "$id" get "$b/$k"
      elif [ "$sub" -lt 56 ]; then
        nk="obj-$(rand_str)"
        if awsx s3 mv "s3://$b/$k" "s3://$b/$nk" >/dev/null 2>&1; then
          objects[$idx]="$b|$nk"; log "$id" mv "$b/$k -> $nk"
        fi
      elif [ "$sub" -lt 76 ]; then
        nk="copy-$(rand_str)"
        if awsx s3 cp "s3://$b/$k" "s3://$b/$nk" >/dev/null 2>&1; then
          objects+=("$b|$nk"); log "$id" cp "$b/$k -> $nk"
        fi
      elif [ "$sub" -lt 92 ]; then
        if awsx s3 rm "s3://$b/$k" >/dev/null 2>&1; then
          unset 'objects[idx]'; objects=("${objects[@]}"); log "$id" rm "$b/$k"
        fi
      else
        awsx s3 ls "s3://$b/" >/dev/null 2>&1 && log "$id" ls "$b/"
      fi
    fi

    sleep "$SLEEP"
  done
}

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT INT TERM

echo "load: ${#ENDPOINTS[@]} node(s) [${ENDPOINTS[*]}] · ${PARALLEL} worker(s) · sleep ${SLEEP}s · count ${COUNT:-∞}"
for w in $(seq 1 "$PARALLEL"); do worker "$w" & PIDS+=("$!"); done
wait

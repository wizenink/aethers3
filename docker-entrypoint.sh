#!/bin/sh
# Each container's node name must use its own reachable IP, so peers found via
# DNS (DNSPoll) can connect to it. Derive it at startup, then run the release.
set -e

IP="$(hostname -i 2>/dev/null | awk '{print $1}')"
[ -z "$IP" ] && IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"

export RELEASE_NODE="${AETHER_NODE_BASENAME:-aether}@${IP}"
echo "[entrypoint] starting as RELEASE_NODE=${RELEASE_NODE}"

exec /app/bin/aether_s3 "$@"

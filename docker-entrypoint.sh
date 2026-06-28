#!/bin/sh
# Node name: if RELEASE_NODE is already set (static-name deploys, one service per
# node), use it as-is. Otherwise derive it from the container IP so peers found
# via DNSPoll can connect to a reachable name (the --scale deploy).
set -e

if [ -z "$RELEASE_NODE" ]; then
  IP="$(hostname -i 2>/dev/null | awk '{print $1}')"
  [ -z "$IP" ] && IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"
  export RELEASE_NODE="${AETHER_NODE_BASENAME:-aether}@${IP}"
fi

echo "[entrypoint] starting as RELEASE_NODE=${RELEASE_NODE}"

exec /app/bin/aether_s3 "$@"

#!/bin/sh
# Node name: if RELEASE_NODE or AETHER_NODE is already set (static-name deploys),
# leave it — env.sh.eex maps AETHER_NODE -> RELEASE_NODE. Otherwise derive it from
# the container IP so peers found via DNSPoll can connect (the --scale deploy).
set -e

if [ -z "$RELEASE_NODE" ] && [ -z "$AETHER_NODE" ]; then
  IP="$(hostname -i 2>/dev/null | awk '{print $1}')"
  [ -z "$IP" ] && IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"
  export RELEASE_NODE="${AETHER_NODE_BASENAME:-aether}@${IP}"
fi

echo "[entrypoint] starting as RELEASE_NODE=${RELEASE_NODE:-$AETHER_NODE}"

# Tag every trace span with this node's identity so a distributed trace shows
# WHICH node ran each span (service.instance.id, shown as a Process tag). Only
# matters when tracing is enabled; harmless otherwise. Preserves any attrs the
# operator already set.
NODE="${RELEASE_NODE:-$AETHER_NODE}"
if [ -n "$NODE" ]; then
  export OTEL_RESOURCE_ATTRIBUTES="service.instance.id=${NODE}${OTEL_RESOURCE_ATTRIBUTES:+,${OTEL_RESOURCE_ATTRIBUTES}}"
fi

exec /app/bin/aether_s3 "$@"

#!/bin/bash

set -x
set -euo pipefail

if [ "${ENABLE_TAILSCALE-}" = true ]; then
    echo "Enabling Tailscale"
    TAILSCALE_APP_NAME="${TAILSCALE_APP_NAME:-${FLY_APP_NAME}-${FLY_REGION}}-${FLY_ALLOC_ID:0:8}"
    /tailscale/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
    /tailscale/tailscale up --authkey=${TAILSCALE_AUTHKEY} --hostname="${TAILSCALE_APP_NAME}" --accept-routes=true
fi

echo "Adding new entry to hosts file"

IPADDR=$(curl ${ECS_CONTAINER_METADATA_URI} | jq -r '.Networks[0].IPv4Addresses[0]')
echo -e "${IPADDR}\tfly-local-6pn" >> /etc/hosts
echo "Added fly alias hostname for ${IPADDR}"

echo "Starting Realtime"
sudo -E -u nobody /app/bin/server

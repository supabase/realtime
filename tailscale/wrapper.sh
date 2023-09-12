#!/bin/bash

set -x
set -euo pipefail

if [ "${ENABLE_TAILSCALE-}" = true ]; then
    echo "Enabling Tailscale"
    TAILSCALE_APP_NAME="${TAILSCALE_APP_NAME:-${FLY_APP_NAME}-${FLY_REGION}}-${FLY_ALLOC_ID:0:8}"
    /tailscale/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
    /tailscale/tailscale up --authkey=${TAILSCALE_AUTHKEY} --hostname="${TAILSCALE_APP_NAME}" --accept-routes=true
fi

echo "Starting Realtime"

if [ "${AWS_EXECUTION_ENV:=none}" = "AWS_ECS_FARGATE" ]; then
    echo "Running migrations"
    sudo -E -u nobody /app/bin/migrate
fi

sudo -E -u nobody /app/bin/server

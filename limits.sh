#!/bin/bash
set -euo pipefail

ulimit -n
if [ ! -z "$RLIMIT_NOFILE" ]; then
    echo "Setting RLIMIT_NOFILE to ${RLIMIT_NOFILE}"
    ulimit -Sn "$RLIMIT_NOFILE"
fi

echo "Starting Realtime in limits.sh"
ulimit -n
exec /app/bin/server

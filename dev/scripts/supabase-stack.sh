#!/usr/bin/env bash
# Starts a project's Supabase CLI stack with Realtime swapped for an image built from this checkout.
# The swapped container keeps the CLI's name, network, aliases and env, so clients can use the
# stack's URL and keys as usual.
#
#   dev/scripts/supabase-stack.sh [--stop] [project-dir]
#
# project-dir holds supabase/config.toml and defaults to test/e2e. Run it again after a change to
# rebuild and swap Realtime. --stop stops the stack.
#
# Stopping and starting the stack brings back the CLI's own Realtime image; run this again after.
#
# This script is an implementation detail and is supposed to be called from mise tasks.
set -euo pipefail

# Parse the arguments: an optional --stop and an optional project directory.
repo=$(cd "$(dirname "$0")/../.." && pwd)
stop=false
project_dir=
for arg in "$@"; do
  case $arg in
    --stop) stop=true ;;
    -*) echo "unknown flag: $arg" >&2; exit 1 ;;
    *) project_dir=$arg ;;
  esac
done
project_dir=$(cd "${project_dir:-$repo/test/e2e}" && pwd)

# Read project_id from the project's config.toml. The CLI names
# the stack's containers and network after it, e.g. supabase_realtime_e2e and supabase_network_e2e.
config=$project_dir/supabase/config.toml
[ -f "$config" ] || { echo "no supabase/config.toml in $project_dir" >&2; exit 1; }
project_id=$(sed -nE 's/^[[:space:]]*project_id[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$config" | head -n 1)
[ -n "$project_id" ] || { echo "no project_id in $config" >&2; exit 1; }

# `supabase` acts on the project in the current directory, so stopping goes through here too.
cd "$project_dir"
if $stop; then
  exec supabase stop
fi

# One tag per project: rebuilding for one project mustn't move the tag another project's container
# runs, or that container's image can't be inspected anymore (see step 2).
image=realtime:supabase-stack-$project_id
realtime_container=supabase_realtime_$project_id
exists() { docker container inspect "$realtime_container" >/dev/null 2>&1; }

# 1. Bring up the stack. Its Realtime container is the source of truth for the env (JWT secret, DB
#    credentials, encryption key). On a running stack `supabase start` does nothing and leaves an
#    earlier swap in place. An earlier swap that failed halfway leaves the stack without Realtime,
#    and `supabase start` doesn't recreate a container removed behind its back, so then the stack
#    is recycled.
supabase start
if ! exists; then
  echo "$realtime_container is missing; recreating the stack..."
  supabase stop >/dev/null 2>&1 || true
  supabase start
fi
exists || { echo "$realtime_container doesn't exist after supabase start; is [realtime] enabled in $config?" >&2; exit 1; }

# 2. Read what the swap carries over from the current container, before building: a rebuild moves
#    our tag, and with the containerd image store the previous image can't be inspected by ID then.
#    - the env the CLI set, minus what the container's image baked in, so ENV changes in our
#      Dockerfile apply. Read from the config rather than `docker exec env`, so a stopped container
#      works too. After a first swap the container is ours, which carries the same env forward.
#    - the labels `supabase stop` finds the stack's containers by
env_file=$(mktemp)
trap 'rm -f "$env_file"' EXIT
envs() { docker "$@" --format '{{range .Config.Env}}{{println .}}{{end}}'; }
image_env=$(envs image inspect "$(docker container inspect --format '{{.Image}}' "$realtime_container")")
container_env=$(envs container inspect "$realtime_container")
grep -vxF -f <(printf '%s\n' "$image_env") <<<"$container_env" | grep -v '^$' > "$env_file" || true

label() { docker container inspect --format "{{index .Config.Labels \"$1\"}}" "$realtime_container"; }
labels=()
for key in com.supabase.cli.project com.docker.compose.project; do
  value=$(label "$key")
  [ -z "$value" ] || labels+=(--label "$key=$value")
done

# 3. Build the checkout. Docker's layer cache keeps rebuilds cheap, and the old container keeps
#    serving until the swap.
docker build -t "$image" "$repo"

# 4. Swap: replace the CLI's container with ours under the same name, network, aliases and
#    healthcheck, so the gateway routes to it unchanged.
docker rm -f "$realtime_container" >/dev/null
docker run -d --name "$realtime_container" \
  --network "supabase_network_$project_id" \
  --network-alias realtime --network-alias realtime-dev \
  ${labels[@]+"${labels[@]}"} \
  --env-file "$env_file" \
  --health-cmd 'curl -sSfL --head -o /dev/null -H "Host:realtime-dev" http://127.0.0.1:4000/api/ping' \
  --health-start-period 120s --health-interval 2s --health-timeout 2s --health-retries 3 \
  "$image" >/dev/null

# 5. Wait until realtime is healthy. Booting runs the tenant migrations, so this can take a while on a
#    fresh database. On failure, show why.
echo "Waiting for $realtime_container to become healthy..."
# A container that exited keeps its last health status, so check that it's still running too.
for _ in $(seq 1 60); do
  state=$(docker container inspect --format '{{.State.Status}} {{.State.Health.Status}}' "$realtime_container" 2>/dev/null || echo missing)
  case $state in
    "running healthy") break ;;
    running*) sleep 2 ;;
    *) break ;;
  esac
done
if [ "$state" != "running healthy" ]; then
  echo "$realtime_container isn't healthy ($state). Its last log lines:" >&2
  docker logs --tail 50 "$realtime_container" >&2 || true
  exit 1
fi

# 6. Show what's running: restarting the stack silently brings back the CLI's own image.
supabase status
echo "Realtime in $realtime_container runs $image, built $(docker image inspect --format '{{.Created}}' "$image")"

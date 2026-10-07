#!/usr/bin/env bash
set -euo pipefail

postgres_release() {
  gh api repos/supabase/postgres/contents/ansible/vars.yml -H "Accept: application/vnd.github.raw" |
    key="$1" yq -e '.postgres_release[strenv(key)]'
}

multigres_revision() {
  docker buildx imagetools inspect ghcr.io/multigres/multigres-cluster-supabase:main \
    --format '{{ index (index .Image "linux/amd64").Config.Labels "org.opencontainers.image.revision" }}'
}

case "${1:-}" in
  pg15)
    entry=pg15_latest
    latest="supabase/postgres:$(postgres_release postgres15)"
    ;;
  pg17)
    entry=pg17
    latest="supabase/postgres:$(postgres_release postgres17)"
    ;;
  orioledb17)
    entry=orioledb17
    latest="supabase/postgres:$(postgres_release postgresorioledb-17)"
    ;;
  multigres)
    entry=multigres
    revision=$(multigres_revision)
    latest="ghcr.io/multigres/multigres-cluster-supabase:sha-${revision:0:7}"
    ;;
  *)
    echo "usage: $0 pg15|pg17|orioledb17|multigres" >&2
    exit 2
    ;;
esac

current=$(jq -er --arg entry "$entry" '.[$entry]' .github/db-images.json)

if [ "$current" != "$latest" ]; then
  # shellcheck disable=SC2016
  git grep -lzF "$current" | FROM="$current" TO="$latest" xargs -0 perl -pi -e 's/\Q$ENV{FROM}\E(?![\w.-])/$ENV{TO}/g'
  echo "Bumps \`$current\` to \`$latest\`."
fi

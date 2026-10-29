#!/usr/bin/env bash
set -euo pipefail

postgres_release() {
  gh api repos/supabase/postgres/contents/ansible/postgres_release.yml -H "Accept: application/vnd.github.raw" |
    key="$1" yq -e '.postgres_release[strenv(key)]'
}

multigres_revision() {
  docker buildx imagetools inspect ghcr.io/multigres/multigres-cluster-supabase:main \
    --format '{{ index (index .Image "linux/amd64").Config.Labels "org.opencontainers.image.revision" }}'
}

entries=$(jq -r 'keys_unsorted[]' .github/db-images.json)

for entry in $entries; do
  case "$entry" in
    pg15_latest)
      latest="supabase/postgres:$(postgres_release postgres15)"
      ;;
    pg17)
      latest="supabase/postgres:$(postgres_release postgres17)"
      ;;
    orioledb17)
      latest="supabase/postgres:$(postgres_release postgresorioledb-17)"
      ;;
    multigres)
      revision=$(multigres_revision)
      latest="ghcr.io/multigres/multigres-cluster-supabase:sha-${revision:0:7}"
      ;;
    *)
      continue
      ;;
  esac

  current=$(jq -er --arg entry "$entry" '.[$entry]' .github/db-images.json)

  if [ "$current" != "$latest" ]; then
    # shellcheck disable=SC2016
    git grep -lzF "$current" | FROM="$current" TO="$latest" xargs -0 perl -pi -e 's/\Q$ENV{FROM}\E(?![\w.-])/$ENV{TO}/g'
    echo "- Bumps \`$current\` to \`$latest\`."
  fi
done

#!/usr/bin/env bash
# Bumps the pinned @supabase/pg-delta to the newest alpha release.
# It is pinned in mise.toml and mise.lock (dev and CI) and, by pg-toolbelt commit, in the Dockerfile (prod).
# Prints the PR body on stdout and, when run by GitHub Actions, the new version as the `version` output.
set -euo pipefail

files=(mise.toml mise.lock Dockerfile)

current=$(sed -nE 's/^"npm:@supabase\/pg-delta" = "([^"]+)"$/\1/p' mise.toml)
current_commit=$(sed -nE 's/^ARG PG_DELTA_COMMIT=([0-9a-f]{40})$/\1/p' Dockerfile)

if [ -z "$current" ] || [ -z "$current_commit" ]; then
  echo "could not read the current pg-delta pin from mise.toml and Dockerfile" >&2
  exit 1
fi

latest=$(npm view @supabase/pg-delta dist-tags.alpha)

if [ "$current" = "$latest" ]; then
  exit 0
fi

# The release tag points at the pg-toolbelt commit the Dockerfile builds from.
latest_commit=$(gh api "repos/supabase/pg-toolbelt/commits/@supabase%2Fpg-delta@${latest}" --jq .sha)

# shellcheck disable=SC2016
FROM="$current" TO="$latest" perl -pi -e 's/\Q$ENV{FROM}\E(?![\w.-])/$ENV{TO}/g' "${files[@]}"
# shellcheck disable=SC2016
FROM="$current_commit" TO="$latest_commit" perl -pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/g' Dockerfile

for file in "${files[@]}"; do
  if ! grep -qF "$latest" "$file"; then
    echo "$file does not pin pg-delta $latest after the bump" >&2
    exit 1
  fi
done

echo "version=$latest" >> "${GITHUB_OUTPUT:-/dev/null}"

echo "- Bumps \`@supabase/pg-delta\` from \`$current\` to \`$latest\`."
echo "- Changes: https://github.com/supabase/pg-toolbelt/compare/${current_commit}...${latest_commit}"

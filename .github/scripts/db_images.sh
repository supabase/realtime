#!/usr/bin/env bash
set -euo pipefail

for assignment in "$@"; do
  key=${assignment#*=}
  image=""
  if [ -n "$key" ]; then
    image=$(jq -er --arg key "$key" '.[$key]' .github/db-images.json)
  fi
  echo "${assignment%%=*}=$image"
done

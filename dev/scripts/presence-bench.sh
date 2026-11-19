#!/usr/bin/env bash
#
# Runs the presence benchmark of dev/bench/presence.exs once and renders the report. The arguments
# are the settings, such as `--tenants 20 --entries 100`. The header of presence.exs lists them and
# explains the figures. Start the realtime database first: `mise run db-start`.
#
# The script always writes the results to _build/presence_bench/latest.json and the report to
# _build/presence_bench/report.html. To compare with an earlier run, copy its results file and pass
# `--compare <file>`. The script changes to the repo root, so a relative path resolves from the
# repo root and not from the current directory.
set -euo pipefail

cd "$(dirname "$0")/../.."

dir=_build/presence_bench
results=$dir/latest.json
report=$dir/report.html

mkdir -p "$dir"

# `--hidden` keeps the coordinator out of the cluster. A member would receive the Phoenix
# replication and add its cost to the measured nodes.
elixir --hidden --name bench@127.0.0.1 --cookie cookie -S mix run --no-start dev/bench/presence.exs \
  ${@+"$@"} --out "$results"

mix run --no-start dev/bench/presence/report.exs "$results" "$report"
echo "Report: $PWD/$report"

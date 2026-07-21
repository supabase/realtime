#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

for n in 1 2 3 4 5 6 7 8; do
  echo
  echo "########## scenario_$n ##########"
  ./scenario_$n.sh
done

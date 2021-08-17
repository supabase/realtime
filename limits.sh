#!/bin/sh
set -e
ulimit -n 100000
exec "$@"
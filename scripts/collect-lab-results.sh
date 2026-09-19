#!/usr/bin/env bash
# Collect experiment results from a live server into lab/results/, validated.
# For a session running ON the server machine -- see docs/LOCAL_SESSION.md.
set -uo pipefail
cd "$(dirname "$0")/.."
exec lua5.4 scripts/collect_lab_results.lua "$@"

#!/usr/bin/env bash
# Tier A test runner (docs/ENVIRONMENT_AUDIT.md §9.3).
# Runs every pure-Lua unit test. Cannot test adapters, natives or events -- those
# need a live FXServer, which cannot boot in CI (audit §6.3).
set -uo pipefail
cd "$(dirname "$0")/.."
exec lua5.4 tests/run.lua "$@"

#!/usr/bin/env bash
# Replay the fixture suite (docs/ARCHITECTURE.md §2 C3).
set -uo pipefail
cd "$(dirname "$0")/.."
exec lua5.4 tests/replay.lua "$@"

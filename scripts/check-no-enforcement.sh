#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
exec lua5.4 scripts/check_no_enforcement.lua

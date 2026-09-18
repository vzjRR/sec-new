#!/usr/bin/env bash
# Tier A verification: everything that can be checked WITHOUT a live FXServer
# (docs/ENVIRONMENT_AUDIT.md §9.3). This is the full CI gate.
set -uo pipefail
cd "$(dirname "$0")/.."

rc=0
run() {
  echo
  echo "=============================================================="
  echo ">> $1"
  echo "=============================================================="
  shift
  "$@" || rc=1
}

run "Lua syntax gate"        bash scripts/lint.sh
run "no-enforcement guard"   bash scripts/check-no-enforcement.sh
run "unit tests"             bash scripts/test.sh

echo
echo "=============================================================="
if [[ $rc -eq 0 ]]; then
  echo "TIER A: PASS"
  echo
  echo "Reminder: Tier A cannot verify resource boot, natives, events or"
  echo "performance. Those require the private local lab (Tier B)."
else
  echo "TIER A: FAIL"
fi
exit $rc

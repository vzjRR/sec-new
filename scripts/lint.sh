#!/usr/bin/env bash
# Syntax gate for every Lua file in the project.
# Uses luac5.4 -p, verified working in docs/ENVIRONMENT_AUDIT.md §9.1.
#
# NOTE: fxmanifest.lua files use FiveM's semi-declarative manifest syntax and are
# valid Lua, so they are checked too. Files that legitimately use CfxLua extensions
# (backtick hash literals, vector3) cannot be parsed by vanilla luac and must be
# listed in .luacheckskip -- keeping that list short is the point of the
# pure-logic/thin-adapter split (docs/ARCHITECTURE.md §2 C2).
set -uo pipefail
cd "$(dirname "$0")/.."

skip_file=".luacheckskip"
fail=0
checked=0

while IFS= read -r f; do
  if [[ -f "$skip_file" ]] && grep -Fxq "$f" "$skip_file"; then
    echo "SKIP  $f (CfxLua extensions)"
    continue
  fi
  if out=$(luac5.4 -p "$f" 2>&1); then
    checked=$((checked+1))
  else
    echo "FAIL  $f"
    echo "      $out"
    fail=$((fail+1))
  fi
done < <(find . -name '*.lua' -not -path './.git/*' | sort)

echo "──────────────────────────────────────────────"
echo "lint: $checked file(s) OK, $fail failure(s)"
[[ $fail -eq 0 ]]

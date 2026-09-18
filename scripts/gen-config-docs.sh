#!/usr/bin/env bash
# Regenerate config/README.md from the config schema, so the reference cannot drift.
set -euo pipefail
cd "$(dirname "$0")/.."
{
  echo "# Configuration reference"
  echo
  echo "**Generated from \`security-core/lib/config.lua\` by \`scripts/gen-config-docs.sh\`.**"
  echo "Do not edit by hand — regenerate instead, so this file cannot drift from the schema."
  echo
  echo "Each key is overridable by a ConVar: \`security_\` + the key with dots replaced by"
  echo "underscores. For example \`poll.movement_ms\` becomes \`security_poll_movement_ms\`."
  echo
  echo "An invalid override is **rejected and the default kept**, with the problem logged."
  echo "Refusing to boot over one bad config line would leave the server with no"
  echo "observability at all, which is worse than running with a sane default."
  echo
  echo '```'
  lua5.4 -e "package.path='resources/[vzjrr-security]/security-core/?.lua;'..package.path; print(require('lib.config').describe())"
  echo '```'
} > config/README.md
echo "wrote config/README.md"

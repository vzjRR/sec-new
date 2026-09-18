-- FiveM Security Lab -- security-forensics
-- Incident model, detection results, timelines, evidence.
-- OBSERVATION ONLY: this resource concludes, it never enforces.

fx_version 'cerulean'
game 'gta5'

name 'security-forensics'
author 'vzjRR'
description 'FiveM Security Lab -- forensics: detection results, incident lifecycle, gap-aware timelines'
version '0.1.0'
repository 'https://github.com/vzjRR/sec-new'

dependency 'security-core'

--[[
  Pure logic only for now. The evidence store and investigation API are the remaining
  Phase 3 items (docs/ROADMAP.md), so this resource has no adapter yet -- it exposes
  its logic to the other security-* resources through the shared SecLab table and,
  once the store exists, through exports.

  Order is load-bearing: detection.lua must precede incident.lua, which reads it.
]]
server_scripts {
    'logic/detection.lua',
    'logic/incident.lua',
    'logic/timeline.lua',
}

provides { 'security-forensics' }

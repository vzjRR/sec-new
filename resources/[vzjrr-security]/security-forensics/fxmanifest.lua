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
dependency 'security-telemetry'

--[[
  Order is load-bearing: detection.lua must precede incident.lua; timeline.lua and
  detection.lua must precede investigation.lua, which reads both; and every logic
  module must precede server/main.lua, which asserts on them.
]]
server_scripts {
    'logic/detection.lua',
    'logic/incident.lua',
    'logic/timeline.lua',
    'logic/evidence.lua',
    'logic/investigation.lua',
    'sinks/file.lua',
    'server/main.lua',
}

provides { 'security-forensics' }

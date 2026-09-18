-- FiveM Security Lab -- security-detectors
-- Detector registry and the detector implementations.
-- A detector never bans, kicks, cancels an event, or mutates game state.

fx_version 'cerulean'
game 'gta5'

name 'security-detectors'
author 'vzjRR'
description 'FiveM Security Lab -- detector registry and detectors (observation only)'
version '0.1.0'
repository 'https://github.com/vzjRR/sec-new'

dependency 'security-core'
dependency 'security-forensics'

--[[
  Pure logic only. `detection.new` lives in security-forensics and FiveM resources
  each have their own Lua state, so it cannot be required here -- the registry takes
  it as an INJECTED function, obtained through an export that passes plain tables
  only (see logic/registry.lua and EXP-010).

  Order is load-bearing: registry.lua before any detector that registers with it.
]]
server_scripts {
    'logic/registry.lua',
    'logic/server_posture.lua',
    'server/main.lua',
}

provides { 'security-detectors' }

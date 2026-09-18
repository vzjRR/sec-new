-- FiveM Security Lab -- security-telemetry
-- Normalized, versioned telemetry. OBSERVATION ONLY: no cancellation, no enforcement.

fx_version 'cerulean'
game 'gta5'

name 'security-telemetry'
author 'vzjRR'
description 'FiveM Security Lab -- telemetry pipeline: event adapters, pollers, normalization, sinks'
version '0.1.0'
repository 'https://github.com/vzjRR/sec-new'

dependency 'security-core'

server_scripts {
    -- pure logic (unit-tested in CI)
    'logic/schema.lua',
    'logic/clock.lua',
    'logic/envelope.lua',
    'logic/normalize.lua',
    'logic/buffer.lua',
    'logic/jsonl.lua',
    -- sinks and adapters (impure; verified on a live server only)
    'sinks/memory.lua',
    'sinks/jsonl.lua',
    'adapters/identity.lua',
    'adapters/events.lua',
    'adapters/pollers.lua',
    'server/main.lua',
}

provides { 'security-telemetry' }

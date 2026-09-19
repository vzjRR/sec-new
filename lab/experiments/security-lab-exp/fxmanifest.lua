-- FiveM Security Lab -- EXPERIMENT HARNESS
--
-- LAB ONLY. This resource measures platform behaviour so that detectors can be built
-- on facts rather than guesses (charter §21). It reads state and records what it
-- sees. It does not modify game state, does not touch players, and performs no
-- enforcement.
--
-- It must NOT be part of a production deployment. Two independent guards
-- (docs/ARCHITECTURE.md §6): it refuses to start unless security_mode is LAB, and it
-- lives under lab/ rather than in the protection resource set.

fx_version 'cerulean'
game 'gta5'

name 'security-lab-exp'
author 'vzjRR'
description 'FiveM Security Lab -- LAB-ONLY experiment harness (EXP-001 .. EXP-010)'
version '0.1.0'
repository 'https://github.com/vzjRR/sec-new'

-- Order is load-bearing: logic before the adapter that asserts on it.
server_scripts {
    'logic/source_scan.lua',
    'logic/recorder.lua',
    'server/main.lua',
}

provides { 'security-lab-exp' }

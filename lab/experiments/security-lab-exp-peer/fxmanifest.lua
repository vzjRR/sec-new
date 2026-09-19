-- FiveM Security Lab -- EXP-010 peer resource
--
-- LAB ONLY. Exists solely so EXP-010 can answer one question: does a table containing
-- functions survive an `exports` call between two resources?
--
-- It must be a SEPARATE resource, because each resource has its own Lua state and
-- calling an export on yourself would not cross the boundary being measured.

fx_version 'cerulean'
game 'gta5'

name 'security-lab-exp-peer'
author 'vzjRR'
description 'FiveM Security Lab -- LAB-ONLY peer resource for EXP-010'
version '0.1.0'

server_scripts { 'server/main.lua' }

provides { 'security-lab-exp-peer' }

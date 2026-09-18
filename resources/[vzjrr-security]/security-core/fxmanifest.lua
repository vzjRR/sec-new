-- FiveM Security Lab -- security-core
-- Boot, configuration, LAB/PRODUCTION mode, structured logging, health, ConVar posture.
--
-- fx_version 'cerulean' is the current FXv2 version per the official resource
-- manifest reference. game 'gta5' targets FiveM.

fx_version 'cerulean'
game 'gta5'

name 'security-core'
author 'vzjRR'
description 'FiveM Security Lab -- core: config, mode, logging, health, ConVar posture audit'
version '0.1.0'
repository 'https://github.com/vzjRR/sec-new'

-- Pure logic first, then the adapter that wires it to the server.
server_scripts {
    'lib/mode.lua',
    'lib/config.lua',
    'lib/logger.lua',
    'lib/posture.lua',
    'server/main.lua',
}

-- Consumed by the other security-* resources.
provides { 'security-core' }

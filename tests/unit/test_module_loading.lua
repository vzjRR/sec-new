--[[
  tests/unit/test_module_loading.lua

  Verifies the dual-export mechanism by SIMULATING FXSERVER'S LOADING MODEL.

  Why this file exists: FiveM has no documented `require` for resource scripts. Every
  file listed in `server_scripts` is loaded as a plain chunk into one shared Lua state
  and its RETURN VALUE IS DISCARDED. An earlier version of this codebase used
  `require 'lib.mode'` in its adapters, which works under vanilla Lua in CI and would
  have failed at boot on a real server — the exact failure mode Tier A is blind to
  (docs/ARCHITECTURE.md §2 C2).

  This test closes that specific gap: it loads each module the way FXServer does
  (`loadfile` + call, discarding the result) and asserts the module is still reachable
  afterwards. It is the only Tier A test that verifies something about the boot path.
]]
local H = ...

local ROOT = 'resources/[vzjrr-security]/'

-- The fxmanifest server_scripts order for each resource. Order is load-bearing:
-- a module must be loaded before anything that reads it off SecLab.
local RESOURCES = {
  {
    name = 'security-core',
    dir = ROOT .. 'security-core/',
    files = { 'lib/mode.lua', 'lib/config.lua', 'lib/logger.lua', 'lib/posture.lua' },
    expect = { 'mode', 'config', 'logger', 'posture' },
  },
  {
    name = 'security-telemetry',
    dir = ROOT .. 'security-telemetry/',
    files = {
      'logic/schema.lua', 'logic/clock.lua', 'logic/envelope.lua',
      'logic/normalize.lua', 'logic/buffer.lua',
      'sinks/memory.lua', 'sinks/jsonl.lua',
    },
    expect = { 'schema', 'clock', 'envelope', 'normalize', 'buffer',
               'sink_memory', 'sink_jsonl' },
  },
  {
    name = 'security-forensics',
    dir = ROOT .. 'security-forensics/',
    files = { 'logic/detection.lua', 'logic/incident.lua', 'logic/timeline.lua' },
    expect = { 'detection', 'incident', 'timeline' },
  },
}

--[[
  Load a resource's scripts the way FXServer does.

  Each chunk gets a fresh environment that shares one `SecLab` table, mimicking a
  per-resource Lua state. The chunk's return value is deliberately thrown away.
]]
local function load_like_fxserver(res)
  local shared = {}                         -- stands in for the resource's globals
  local env = setmetatable(shared, { __index = _G })
  shared.SecLab = nil                       -- starts empty, as a fresh state would

  for _, rel in ipairs(res.files) do
    local path = res.dir .. rel
    local chunk, err = loadfile(path, 't', env)
    if not chunk then return nil, ('loadfile failed for %s: %s'):format(path, tostring(err)) end
    local ok, cerr = pcall(chunk)           -- return value intentionally discarded
    if not ok then return nil, ('chunk error in %s: %s'):format(path, tostring(cerr)) end
  end
  return shared.SecLab, nil
end

H.suite('module loading: FXServer model (return value discarded)')

for _, res in ipairs(RESOURCES) do
  H.test(res.name .. ': every module self-publishes to SecLab', function()
    local ns, err = load_like_fxserver(res)
    H.ok(ns, 'loading failed: ' .. tostring(err))
    for _, key in ipairs(res.expect) do
      H.eq(type(ns[key]), 'table',
        ('%s.%s must be reachable after load (FiveM discards chunk returns)')
          :format(res.name, key))
    end
  end)
end

H.test('a module that needs a sibling resolves it from SecLab, not require', function()
  -- envelope.lua depends on schema.lua. Under FXServer there is no `require`, so it
  -- must find schema on the shared table.
  local res = RESOURCES[2]
  local ns = assert(load_like_fxserver(res))
  H.eq(type(ns.envelope), 'table')
  H.eq(type(ns.schema), 'table')
end)

H.test('incident.lua resolves detection.lua from SecLab', function()
  local ns = assert(load_like_fxserver(RESOURCES[3]))
  H.eq(type(ns.incident), 'table')
  H.eq(type(ns.detection), 'table')
end)

H.suite('module loading: the published module actually works')

H.test('a SecLab-loaded module is functional, not just present', function()
  -- Presence is not enough: the published table must be the real module.
  local ns = assert(load_like_fxserver(RESOURCES[1]))
  H.eq(ns.mode.resolve('LAB'), 'LAB')
  H.eq(ns.mode.resolve('typo'), 'PRODUCTION')
  H.eq(ns.config.defaults()['detectors.enabled'], false)
  local findings = ns.posture.audit({})
  H.ok(#findings > 0, 'posture.audit should work when loaded the FXServer way')
end)

H.test('a telemetry record can be built end to end via SecLab only', function()
  local ns = assert(load_like_fxserver(RESOURCES[2]))
  local c = ns.clock.new(function() return 1758204000000 end, function() return 500 end)
  local b = ns.envelope.new(c, { mode = 'LAB' })
  local rec = ns.normalize.weapon_damage(b, 'QB:ABCD1234', 7,
    { weaponType = 1, weaponDamage = 35, hitGlobalIds = { 9 } })
  local ok, errs = ns.schema.validate(rec)
  H.ok(ok, 'record invalid: ' .. table.concat(errs, '; '))
  H.eq(rec.trust, 'claimed')
end)

H.suite('module loading: fxmanifest order matches reality')

for _, res in ipairs(RESOURCES) do
  H.test(res.name .. ': fxmanifest lists every module this test loads', function()
    -- If a module is added to the resource but not to fxmanifest, it silently never
    -- loads on a real server. Keep the manifest and this list in agreement.
    local fh = assert(io.open(res.dir .. 'fxmanifest.lua', 'r'),
      'missing fxmanifest for ' .. res.name)
    local manifest = fh:read('a'); fh:close()
    for _, rel in ipairs(res.files) do
      H.ok(manifest:find(rel, 1, true),
        ('fxmanifest.lua for %s does not list %s'):format(res.name, rel))
    end
  end)
end

H.test('security-core lists lib modules BEFORE server/main.lua', function()
  -- server/main.lua reads SecLab at load time, so order is load-bearing.
  local fh = assert(io.open(ROOT .. 'security-core/fxmanifest.lua', 'r'))
  local m = fh:read('a'); fh:close()
  local main_at = m:find('server/main.lua', 1, true)
  H.ok(main_at, 'server/main.lua must be listed')
  for _, rel in ipairs({ 'lib/mode.lua', 'lib/config.lua', 'lib/logger.lua', 'lib/posture.lua' }) do
    local at = m:find(rel, 1, true)
    H.ok(at and at < main_at, rel .. ' must be listed before server/main.lua')
  end
end)

H.test('security-telemetry lists logic and adapters BEFORE server/main.lua', function()
  local fh = assert(io.open(ROOT .. 'security-telemetry/fxmanifest.lua', 'r'))
  local m = fh:read('a'); fh:close()
  local main_at = m:find('server/main.lua', 1, true)
  H.ok(main_at)
  for _, rel in ipairs({ 'logic/schema.lua', 'logic/buffer.lua', 'sinks/jsonl.lua',
                         'adapters/identity.lua', 'adapters/pollers.lua' }) do
    local at = m:find(rel, 1, true)
    H.ok(at and at < main_at, rel .. ' must be listed before server/main.lua')
  end
end)

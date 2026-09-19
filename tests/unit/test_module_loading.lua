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
      'logic/normalize.lua', 'logic/buffer.lua', 'logic/jsonl.lua',
      'sinks/memory.lua', 'sinks/jsonl.lua',
    },
    expect = { 'schema', 'clock', 'envelope', 'normalize', 'buffer', 'jsonl',
               'sink_memory', 'sink_jsonl' },
  },
  {
    name = 'security-detectors',
    dir = ROOT .. 'security-detectors/',
    files = { 'logic/registry.lua', 'logic/window.lua',
              'logic/server_posture.lua', 'logic/entity_rate.lua' },
    expect = { 'registry', 'window', 'server_posture', 'entity_rate' },
  },
  {
    name = 'security-lab-exp',
    dir = 'lab/experiments/security-lab-exp/',
    files = { 'logic/source_scan.lua', 'logic/recorder.lua' },
    -- dir is repo-relative rather than under ROOT: the lab harness deliberately
    -- lives outside the protection resource set (docs/ARCHITECTURE.md §6).
    expect = { 'source_scan', 'recorder' },
  },
  {
    name = 'security-forensics',
    dir = ROOT .. 'security-forensics/',
    files = { 'logic/detection.lua', 'logic/incident.lua', 'logic/timeline.lua',
              'logic/evidence.lua', 'logic/investigation.lua', 'sinks/file.lua' },
    expect = { 'detection', 'incident', 'timeline', 'evidence', 'investigation',
               'sink_file' },
  },
}

local function resource(name)
  for _, r in ipairs(RESOURCES) do if r.name == name then return r end end
  error('no such resource in this test: ' .. name)
end

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

--[[
  Find a script entry's position in a manifest.

  Matches the QUOTED form ('server/main.lua'), not the bare path: the manifests
  discuss load order in their comments, and an earlier prose mention would otherwise
  satisfy an ordering assertion that the actual entries violate. That exact
  false pass happened once.
]]
local function entry_pos(manifest, rel)
  return manifest:find("'" .. rel .. "'", 1, true)
       or manifest:find('"' .. rel .. '"', 1, true)
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
  local ns = assert(load_like_fxserver(resource('security-telemetry')))
  H.eq(type(ns.envelope), 'table')
  H.eq(type(ns.schema), 'table')
end)

H.test('incident.lua resolves detection.lua from SecLab', function()
  local forensics
  for _, r in ipairs(RESOURCES) do
    if r.name == 'security-forensics' then forensics = r end
  end
  local ns = assert(load_like_fxserver(forensics))
  H.eq(type(ns.incident), 'table')
  H.eq(type(ns.detection), 'table')
end)

H.suite('module loading: the published module actually works')

H.test('a SecLab-loaded module is functional, not just present', function()
  -- Presence is not enough: the published table must be the real module.
  local ns = assert(load_like_fxserver(resource('security-core')))
  H.eq(ns.mode.resolve('LAB'), 'LAB')
  H.eq(ns.mode.resolve('typo'), 'PRODUCTION')
  H.eq(ns.config.defaults()['detectors.enabled'], false)
  local findings = ns.posture.audit({})
  H.ok(#findings > 0, 'posture.audit should work when loaded the FXServer way')
end)

H.test('a telemetry record can be built end to end via SecLab only', function()
  local ns = assert(load_like_fxserver(resource('security-telemetry')))
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
      H.ok(entry_pos(manifest, rel),
        ('fxmanifest.lua for %s does not list %s'):format(res.name, rel))
    end
  end)
end

H.test('security-core lists lib modules BEFORE server/main.lua', function()
  -- server/main.lua reads SecLab at load time, so order is load-bearing.
  local fh = assert(io.open(ROOT .. 'security-core/fxmanifest.lua', 'r'))
  local m = fh:read('a'); fh:close()
  local main_at = entry_pos(m, 'server/main.lua')
  H.ok(main_at, 'server/main.lua must be listed')
  for _, rel in ipairs({ 'lib/mode.lua', 'lib/config.lua', 'lib/logger.lua', 'lib/posture.lua' }) do
    local at = entry_pos(m, rel)
    H.ok(at and at < main_at, rel .. ' must be listed before server/main.lua')
  end
end)

H.test('security-lab-exp lists logic BEFORE server/main.lua', function()
  local fh = assert(io.open('lab/experiments/security-lab-exp/fxmanifest.lua', 'r'))
  local m = fh:read('a'); fh:close()
  local main_at = entry_pos(m, 'server/main.lua')
  H.ok(main_at, 'server/main.lua must be listed')
  for _, rel in ipairs({ 'logic/source_scan.lua', 'logic/recorder.lua' }) do
    local at = entry_pos(m, rel)
    H.ok(at and at < main_at, rel .. ' must be listed before server/main.lua')
  end
end)

H.test('security-detectors lists logic BEFORE server/main.lua', function()
  local fh = assert(io.open(ROOT .. 'security-detectors/fxmanifest.lua', 'r'))
  local m = fh:read('a'); fh:close()
  local main_at = entry_pos(m, 'server/main.lua')
  H.ok(main_at, 'server/main.lua must be listed')
  for _, rel in ipairs({ 'logic/registry.lua', 'logic/window.lua',
                         'logic/server_posture.lua', 'logic/entity_rate.lua' }) do
    local at = entry_pos(m, rel)
    H.ok(at and at < main_at, rel .. ' must be listed before server/main.lua')
  end
end)

H.test('security-forensics lists logic and sinks BEFORE server/main.lua', function()
  local fh = assert(io.open(ROOT .. 'security-forensics/fxmanifest.lua', 'r'))
  local m = fh:read('a'); fh:close()
  local main_at = entry_pos(m, 'server/main.lua')
  H.ok(main_at, 'server/main.lua must be listed')
  for _, rel in ipairs({ 'logic/detection.lua', 'logic/incident.lua', 'logic/timeline.lua',
                         'logic/evidence.lua', 'logic/investigation.lua', 'sinks/file.lua' }) do
    local at = entry_pos(m, rel)
    H.ok(at and at < main_at, rel .. ' must be listed before server/main.lua')
  end
end)

H.test('security-telemetry lists logic and adapters BEFORE server/main.lua', function()
  local fh = assert(io.open(ROOT .. 'security-telemetry/fxmanifest.lua', 'r'))
  local m = fh:read('a'); fh:close()
  local main_at = entry_pos(m, 'server/main.lua')
  H.ok(main_at)
  for _, rel in ipairs({ 'logic/schema.lua', 'logic/buffer.lua', 'sinks/jsonl.lua',
                         'adapters/identity.lua', 'adapters/pollers.lua' }) do
    local at = entry_pos(m, rel)
    H.ok(at and at < main_at, rel .. ' must be listed before server/main.lua')
  end
end)

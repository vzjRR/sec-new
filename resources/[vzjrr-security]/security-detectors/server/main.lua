--[[
  security-detectors / server / main.lua

  ADAPTER. Builds the registry, registers the detectors, and runs the periodic pass.

  OBSERVATION ONLY. A detection is recorded as evidence. Nothing here bans, kicks,
  cancels an event, or mutates game state, and scripts/check_no_enforcement.lua fails
  the build if that changes.

  Detection is OFF by default (charter §4); `detectors.enabled` gates every run.
]]

local function need(key)
  return assert(SecLab and SecLab[key],
    'security-detectors: module "' .. key .. '" did not load -- check fxmanifest order')
end

local registry_lib = need('registry')
local posture_det  = need('server_posture')
local entity_rate  = need('entity_rate')

local RESOURCE = GetCurrentResourceName()

local State = { ready = false, registry = nil, cfg = nil, last_run_mono = nil,
                runs_n = 0, results_n = 0, errors_n = 0,
                -- Per-detector rolling state. The detector is pure; the adapter owns
                -- the state it transitions, which keeps the detector deterministic
                -- and testable (CLAUDE.md §11).
                entity_state = nil, records_n = 0 }

local function log(level, msg, fields)
  local parts = {}
  for k, v in pairs(fields or {}) do parts[#parts + 1] = k .. '=' .. tostring(v) end
  table.sort(parts)
  print(('[%s] %s: %s%s'):format(RESOURCE, level:upper(), msg,
    #parts > 0 and ('  ' .. table.concat(parts, ' ')) or ''))
end

--[[
  Obtain `detection.new` from security-forensics.

  It lives in another Lua state, so it is reached through an export that passes and
  returns plain tables only. The wrapper restores the (result, errors) shape the pure
  registry and detectors expect, so neither has to know the boundary exists.
]]
local function make_detection_new()
  local forensics = exports['security-forensics']
  return function(spec)
    local ok, out = pcall(function() return forensics:newDetection(spec) end)
    if not ok then return nil, { 'forensics newDetection failed: ' .. tostring(out) } end
    if type(out) ~= 'table' then return nil, { 'forensics newDetection returned nothing' } end
    return out.result, out.errors or {}
  end
end

local function run_periodic_pass()
  if not State.ready then return end
  local core = exports['security-core']

  -- posture.audit() lives in security-core; its findings are plain tables, so the
  -- detector stays a pure transform of data that crossed the boundary safely.
  local ok, posture = pcall(function() return core:getPosture() end)
  if not ok or type(posture) ~= 'table' then
    log('error', 'could not read posture from security-core', { err = tostring(posture) })
    return
  end
  local blind_ok, blind, blind_reason = pcall(function() return core:isBlind() end)

  local context = {
    findings     = posture.findings or {},
    summary      = posture.summary,
    blind        = blind_ok and blind or false,
    blind_reason = blind_ok and blind_reason or nil,
    ts           = math.floor(os.time() * 1000),
    mono         = GetGameTimer(),
  }

  local results, errors = State.registry:run_periodic(context, State.cfg)
  State.runs_n = State.runs_n + 1
  State.results_n = State.results_n + #results
  State.errors_n = State.errors_n + #errors
  State.last_run_mono = context.mono

  local forensics = exports['security-forensics']
  for _, r in ipairs(results) do
    -- Detections are recorded as evidence. That is the whole action taken.
    pcall(function() forensics:recordDetection(r) end)
  end

  for _, e in ipairs(errors) do
    log('error', 'detector error', { detector = e.detector_id, err = e.err })
  end

  if #results > 0 then
    log('warn', 'posture detections recorded', {
      results_n = #results, worst = results[1] and results[1].severity or nil,
    })
  end
end

local function boot()
  State.cfg = exports['security-core']:getConfig()

  local detection_new = make_detection_new()
  State.registry = registry_lib.new({ detection_new = detection_new })

  local ok, err = State.registry:register(posture_det.spec({ detection_new = detection_new }))
  if not ok then
    log('error', 'could not register server.posture', { err = tostring(err) })
    return
  end

  State.entity_state = entity_rate.new_state(State.cfg)
  local ok_er, err_er = State.registry:register(
    entity_rate.spec({ detection_new = detection_new }))
  if not ok_er then
    log('error', 'could not register entity.rate', { err = tostring(err_er) })
  end

  State.ready = true
  log('info', 'detector registry ready', {
    detectors = table.concat(State.registry:ids(), ','),
    detection_enabled = State.cfg['detectors.enabled'],
  })

  if not State.cfg['detectors.enabled'] then
    -- Say so loudly: a silent no-op would look like "no problems found".
    log('warn', 'detection is DISABLED by configuration; no detector will run', {
      remediation = 'set security_detectors_enabled true',
    })
    return
  end

  run_periodic_pass()

  CreateThread(function()
    while true do
      Wait(State.cfg['posture.recheck_ms'] or 300000)
      pcall(run_periodic_pass)
    end
  end)
end

--[[
  Feed one telemetry record to the record detectors.

  security-telemetry calls this; results are recorded as evidence and nothing else
  happens. Wrapped so a detector fault can never propagate into the telemetry hot
  path -- an anti-cheat that breaks observability is worse than one that misses.
]]
local function on_record(record)
  if not State.ready or type(record) ~= 'table' then return 0 end
  State.records_n = State.records_n + 1

  local results, errors = State.registry:run_record(
    State.entity_state, record, State.cfg)

  local forensics = exports['security-forensics']
  for _, r in ipairs(results) do
    pcall(function() forensics:recordDetection(r) end)
  end
  for _, e in ipairs(errors) do
    log('error', 'record detector error', { detector = e.detector_id, err = e.err })
  end
  State.results_n = State.results_n + #results
  State.errors_n = State.errors_n + #errors
  return #results
end

exports('onRecord', on_record)

--- Forget a player's rolling state when they disconnect, so it cannot grow forever.
AddEventHandler('playerDropped', function()
  local src = source
  pcall(function()
    if not State.ready then return end
    local key = 'SRC:' .. tostring(src)
    entity_rate.forget(State.entity_state, key)
  end)
end)

-- Housekeeping: drop idle window keys so an idle server's tables shrink.
CreateThread(function()
  while true do
    Wait(60000)
    if State.ready and State.entity_state then
      pcall(function() entity_rate.prune(State.entity_state, GetGameTimer()) end)
    end
  end
end)

exports('health', function()
  return {
    ready         = State.ready,
    enabled       = State.cfg and State.cfg['detectors.enabled'] or false,
    detectors     = State.registry and State.registry:stats() or nil,
    runs_n        = State.runs_n,
    records_n     = State.records_n,
    results_n     = State.results_n,
    errors_n      = State.errors_n,
    last_run_mono = State.last_run_mono,
    entity_rate   = State.entity_state and entity_rate.stats(State.entity_state) or nil,
  }
end)

exports('runPeriodic', function()
  local ok, err = pcall(run_periodic_pass)
  return { ok = ok, err = not ok and tostring(err) or nil }
end)

AddEventHandler('onResourceStart', function(resource)
  if resource ~= RESOURCE then return end
  local ok, err = pcall(boot)
  if not ok then log('error', 'FATAL during boot', { err = tostring(err) }) end
end)

AddEventHandler('onResourceStop', function(resource)
  if resource ~= RESOURCE then return end
  State.ready = false
  log('info', 'detectors stopped', { runs_n = State.runs_n, results_n = State.results_n })
end)

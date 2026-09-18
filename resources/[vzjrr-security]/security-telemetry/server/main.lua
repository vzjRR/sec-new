--[[
  security-telemetry / server / main.lua

  ADAPTER. Wires the pure telemetry core to FXServer and to security-core's config.

  OBSERVATION ONLY. Nothing here cancels an event, kicks a player, or mutates game
  state (charter §4, §10).
]]

--[[
  Modules are published on the resource-scoped `SecLab` table by earlier
  `server_scripts` entries; FiveM has no `require` for resource scripts. The
  fxmanifest order is load-bearing and these asserts fail loudly if it breaks.
]]
local function need(key)
  return assert(SecLab and SecLab[key],
    'security-telemetry: module "' .. key .. '" did not load -- check fxmanifest order')
end

local schema      = need('schema')
local clock_lib   = need('clock')
local envelope    = need('envelope')
local normalize   = need('normalize')
local buffer_lib  = need('buffer')
local memory_sink = need('sink_memory')
local jsonl_sink  = need('sink_jsonl')
local identity    = need('identity')
local events      = need('events')
local pollers     = need('pollers')

local RESOURCE = GetCurrentResourceName()

local State = {
  ready = false, cfg = nil, sink = nil, buffer = nil, builder = nil,
  clock = nil, log = nil, invalid_n = 0, emitted_n = 0,
}

local function simple_log(level, msg, fields)
  local parts = {}
  for k, v in pairs(fields or {}) do parts[#parts + 1] = k .. '=' .. tostring(v) end
  table.sort(parts)
  print(('[%s] %s: %s%s'):format(RESOURCE, level:upper(), msg,
    #parts > 0 and ('  ' .. table.concat(parts, ' ')) or ''))
end

local log = {
  info  = function(_, m, f) simple_log('info', m, f) end,
  warn  = function(_, m, f) simple_log('warn', m, f) end,
  error = function(_, m, f) simple_log('error', m, f) end,
  debug = function(_, m, f) simple_log('debug', m, f) end,
}

local function make_sink(name)
  if name == 'memory' then return memory_sink.new() end
  if name == 'jsonl'  then return jsonl_sink.new({ root = 'telemetry' }) end
  if name == 'stdout' then
    return {
      name = 'stdout',
      write = function(rec)
        local ok, s = pcall(json.encode, rec)
        print('[telemetry] ' .. (ok and s or '<encode failed>'))
        return true
      end,
      flush = function() return true end,
      stats = function() return {} end,
    }
  end
  return { name = 'none', write = function() return true end,
           flush = function() return true end, stats = function() return {} end }
end

--- The single entry point every adapter uses.
local function emit(record)
  if not State.ready or not record then return false end

  if State.cfg['telemetry.validate_records'] then
    local ok, errs = schema.validate(record)
    if not ok then
      -- An invalid record is an ADAPTER bug. Reject it loudly rather than letting it
      -- poison the evidence store, and never crash the game server over it.
      State.invalid_n = State.invalid_n + 1
      log:error('rejected invalid telemetry record', {
        event = tostring(record.event), reason = errs[1],
      })
      return false
    end
  end

  State.buffer:push(record)
  State.emitted_n = State.emitted_n + 1
  return true
end

local function flush()
  if not State.ready then return 0 end
  local batch = State.buffer:drain()
  for _, rec in ipairs(batch) do
    pcall(State.sink.write, rec)
  end
  if #batch > 0 then pcall(State.sink.flush) end
  return #batch
end

local function boot()
  local core = exports['security-core']
  State.cfg = core:getConfig()

  if not State.cfg['telemetry.enabled'] then
    log:warn('telemetry is disabled by configuration')
    return
  end

  local blind, blind_reason = core:isBlind()
  if blind then
    -- Do not pretend to provide coverage we cannot provide.
    log:error('starting telemetry on a server that is NOT state-aware', {
      reason = blind_reason,
      consequence = 'combat, aim and entity telemetry will be absent',
    })
  end

  local wall_ms, mono_ms = core:clockSources()
  State.clock   = clock_lib.new(wall_ms, mono_ms)
  State.builder = envelope.new(State.clock, { mode = core:getMode() })
  State.buffer  = buffer_lib.new(State.cfg['telemetry.buffer_size'])
  State.sink    = make_sink(State.cfg['telemetry.sink'])
  State.ready   = true

  local deps = {
    normalize = normalize, identity = identity, emit = emit,
    config = State.cfg, log = log, builder = State.builder,
    mono = function() return State.clock:mono() end,
  }

  events.install(deps)
  pollers.install(deps)

  -- Flush on a short timer: bounded latency to disk without a write per record.
  CreateThread(function()
    while true do
      Wait(1000)
      if State.ready then pcall(flush) end
    end
  end)

  emit(normalize.system(State.builder, 'telemetry_started', {
    buffer_capacity_n = State.buffer:capacity(),
  }, {
    sink = State.sink.name,
    mode = core:getMode(),
    framework = tostring(identity.framework_status().available),
  }))

  log:info('telemetry ready', {
    sink = State.sink.name,
    buffer_n = State.buffer:capacity(),
    schema_version = schema.SCHEMA_VERSION,
  })
end

exports('health', function()
  return {
    ready      = State.ready,
    schema_version = schema.SCHEMA_VERSION,
    emitted_n  = State.emitted_n,
    invalid_n  = State.invalid_n,
    buffer     = State.buffer and State.buffer:stats() or nil,
    sink       = State.sink and { name = State.sink.name, stats = State.sink.stats() } or nil,
    framework  = identity.framework_status(),
    clock_regressions_n = State.clock and State.clock:regressions() or 0,
  }
end)

exports('emit', emit)
exports('flush', flush)

AddEventHandler('onResourceStart', function(resource)
  if resource ~= RESOURCE then return end
  local ok, err = pcall(boot)
  if not ok then log:error('FATAL during boot', { err = tostring(err) }) end
end)

AddEventHandler('onResourceStop', function(resource)
  if resource ~= RESOURCE then return end
  -- Flush before dying: unflushed evidence is lost evidence.
  pcall(flush)
  if State.sink and State.sink.close then pcall(State.sink.close) end
  State.ready = false
  log:info('telemetry stopped', { emitted_n = State.emitted_n })
end)

--[[
  security-forensics / server / main.lua

  ADAPTER. Wires the pure forensics logic to FXServer and publishes it to the other
  security-* resources.

  The `newDetection` export is the important part. `detection.new` lives here, but
  security-detectors runs in its own Lua state and cannot require it. Rather than
  depend on whether a table of functions survives an export call (UNVERIFIED --
  EXP-010), this export takes and returns PLAIN TABLES ONLY, so it works under either
  answer.
]]

local function need(key)
  return assert(SecLab and SecLab[key],
    'security-forensics: module "' .. key .. '" did not load -- check fxmanifest order')
end

local detection     = need('detection')
local incident_lib  = need('incident')
local timeline_lib  = need('timeline')
local evidence_lib  = need('evidence')
local investigation = need('investigation')
local file_sink     = need('sink_file')

local RESOURCE = GetCurrentResourceName()

local State = { ready = false, store = nil, backend = nil, cfg = nil, incidents = {} }

local function log(level, msg, fields)
  local parts = {}
  for k, v in pairs(fields or {}) do parts[#parts + 1] = k .. '=' .. tostring(v) end
  table.sort(parts)
  print(('[%s] %s: %s%s'):format(RESOURCE, level:upper(), msg,
    #parts > 0 and ('  ' .. table.concat(parts, ' ')) or ''))
end

local function boot()
  local core = exports['security-core']
  State.cfg = core:getConfig()

  -- The JSON codec lives in security-telemetry, which is a different Lua state, so
  -- this resource cannot require it. Encoding is therefore requested through that
  -- resource's export, which passes plain tables and returns a string.
  local telemetry = exports['security-telemetry']

  local deps = {
    encode_line = function(v)
      local ok, line, err = pcall(function() return telemetry:encodeLine(v) end)
      if not ok then return nil, tostring(line) end
      if type(line) ~= 'string' then return nil, tostring(err or 'encode failed') end
      return line
    end,
    decode_lines = function(body)
      local ok, out = pcall(function() return telemetry:decodeLines(body) end)
      if not ok or type(out) ~= 'table' then return {}, { { line = 0, err = 'decode unavailable' } } end
      return out.records or {}, out.errors or {}
    end,
  }

  State.backend = file_sink.new()
  State.store = evidence_lib.new(State.backend, deps, {
    root = 'evidence',
    day  = function() return os.date('!%Y-%m-%d') end,
  })
  State.ready = true

  log('info', 'forensics ready', { store = 'file', root = 'evidence' })
  log('info', 'observation only: this resource concludes, it never enforces')
end

-- ---------------------------------------------------------------------------
-- Exports. Plain tables in, plain tables out.
-- ---------------------------------------------------------------------------

exports('newDetection', function(spec)
  local result, errors = detection.new(spec)
  return { result = result, errors = errors }
end)

exports('recordDetection', function(result)
  if not State.ready then return { ok = false, err = 'forensics not ready' } end
  local ok, err = State.store:append_detection(result)
  return { ok = ok, err = err }
end)

exports('recordTelemetry', function(record)
  if not State.ready then return { ok = false, err = 'forensics not ready' } end
  local ok, err = State.store:append_record(record)
  return { ok = ok, err = err }
end)

exports('openIncident', function(id, player_key, ts, mono)
  local ok, inc = pcall(incident_lib.new, {
    id = id, player_key = player_key, ts = ts, mono = mono,
  })
  if not ok then return { ok = false, err = tostring(inc) } end
  State.incidents[id] = inc
  return { ok = true, id = id }
end)

exports('incidentSummary', function(id)
  local inc = State.incidents[id]
  if not inc then return nil end
  return inc:summary()
end)

--- Render an investigation bundle as text. The primary human-facing output for now.
exports('renderInvestigation', function(id, records)
  local inc = State.incidents[id]
  if not inc then return nil end
  local complete, note = State.store and State.store:is_complete()
  local bundle = investigation.build(inc, records or {}, {
    store_complete = complete, store_note = note,
  })
  return investigation.render(bundle)
end)

exports('buildTimeline', function(records, opts)
  return timeline_lib.build(records or {}, opts or {})
end)

exports('health', function()
  return {
    ready        = State.ready,
    store        = State.store and State.store:stats() or nil,
    store_complete = State.store and (State.store:is_complete()) or nil,
    backend      = State.backend and State.backend.stats() or nil,
    incidents_n  = (function()
      local n = 0
      for _ in pairs(State.incidents) do n = n + 1 end
      return n
    end)(),
  }
end)

AddEventHandler('onResourceStart', function(resource)
  if resource ~= RESOURCE then return end
  local ok, err = pcall(boot)
  if not ok then log('error', 'FATAL during boot', { err = tostring(err) }) end
end)

AddEventHandler('onResourceStop', function(resource)
  if resource ~= RESOURCE then return end
  -- Close handles so buffered evidence is not lost.
  if State.backend and State.backend.close then pcall(State.backend.close) end
  State.ready = false
  log('info', 'forensics stopped')
end)

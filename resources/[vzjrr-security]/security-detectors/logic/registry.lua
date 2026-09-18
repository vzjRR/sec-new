--[[
  security-detectors / logic / registry.lua

  PURE LUA. Holds the registered detectors and runs them safely.

  ---------------------------------------------------------------------------
  TWO DETECTOR KINDS, and why that is not a smell.

  CLAUDE.md §11 defines a detector as `detect(state, record, config)`. That fits a
  behavioural detector, which reasons about a stream of telemetry. It does not fit the
  ConVar posture audit, whose subject is the server's configuration rather than any
  record -- forcing it through a per-record interface would mean inventing a fake
  record to trigger it.

  So the registry knows two kinds:

    'record'   detect(state, record, config)  -> DetectionResult | nil
    'periodic' evaluate(context, config)      -> { DetectionResult, ... }

  Both are pure. Both return results built through the same `detection_new`. The
  distinction is what triggers them, not what they may do.

  ---------------------------------------------------------------------------
  CROSS-RESOURCE CONSTRAINT.

  `detection.new` lives in security-forensics, and FiveM resources each have their own
  Lua state, so this resource cannot `require` it. Whether a table containing
  functions survives an `exports` call is UNVERIFIED (EXP-010), so the design avoids
  depending on the answer: a single function, `detection_new`, is INJECTED, and the
  adapter obtains it through an export that passes and returns plain tables only.
  Nothing about this module changes whichever way EXP-010 resolves.
  ---------------------------------------------------------------------------
]]

local M = {}

M.KIND_RECORD   = 'record'
M.KIND_PERIODIC = 'periodic'

--[[
  A detector that throws repeatedly is disabled rather than retried forever.

  Reasoning: a broken detector must not be able to degrade observability
  indefinitely. But auto-disabling on a single failure would be too eager -- a
  transient nil from malformed telemetry is exactly what a detector should survive and
  what `pcall` already contains. Three consecutive failures means the detector is
  broken, not unlucky. A success resets the counter, so an intermittent fault does not
  accumulate towards a trip.
]]
M.DEFAULT_MAX_CONSECUTIVE_FAILURES = 3

local Registry = {}
Registry.__index = Registry

--- @param deps { detection_new = fn(spec) -> result, errors }
-- @param opts { max_consecutive_failures = 3 }
function M.new(deps, opts)
  assert(type(deps) == 'table' and type(deps.detection_new) == 'function',
    'registry: deps.detection_new must be a function')
  opts = opts or {}
  return setmetatable({
    _detection_new = deps.detection_new,
    _max_failures  = opts.max_consecutive_failures or M.DEFAULT_MAX_CONSECUTIVE_FAILURES,
    _detectors     = {},   -- ordered
    _by_id         = {},
    _stats         = {},   -- [id] = { runs_n, results_n, errors_n, consecutive_n, tripped }
  }, Registry)
end

--[[
  Register a detector.

  spec = {
    id      = 'server.posture',
    version = 1,
    kind    = 'record' | 'periodic',
    fn      = function(...) end,
    enabled = true,           -- optional; config can still gate it
  }
]]
function Registry:register(spec)
  if type(spec) ~= 'table' then return false, 'spec must be a table' end
  if type(spec.id) ~= 'string' or spec.id == '' then return false, 'id required' end
  if self._by_id[spec.id] then
    return false, string.format('detector %q is already registered', spec.id)
  end
  if type(spec.version) ~= 'number' or spec.version < 1 then
    return false, 'version must be a positive number'
  end
  if spec.kind ~= M.KIND_RECORD and spec.kind ~= M.KIND_PERIODIC then
    return false, string.format('kind %q must be "record" or "periodic"', tostring(spec.kind))
  end
  if type(spec.fn) ~= 'function' then return false, 'fn must be a function' end

  local entry = {
    id = spec.id, version = spec.version, kind = spec.kind, fn = spec.fn,
    enabled = spec.enabled ~= false,
  }
  self._detectors[#self._detectors + 1] = entry
  self._by_id[spec.id] = entry
  self._stats[spec.id] = {
    runs_n = 0, results_n = 0, errors_n = 0, consecutive_n = 0,
    tripped = false, trip_reason = nil,
  }
  return true, nil
end

function Registry:get(id) return self._by_id[id] end

function Registry:ids()
  local out = {}
  for _, d in ipairs(self._detectors) do out[#out + 1] = d.id end
  return out
end

function Registry:set_enabled(id, enabled)
  local d = self._by_id[id]
  if not d then return false, 'no such detector' end
  d.enabled = enabled and true or false
  return true
end

local function is_runnable(self, entry, config)
  if not entry.enabled then return false end
  local st = self._stats[entry.id]
  if st.tripped then return false end
  -- Detection is OFF by default (charter §4); config has the final say.
  if config and config['detectors.enabled'] == false then return false end
  return true
end

--[[
  Validate what a detector returned.

  Two checks beyond "is it a table":

  1. `detector_id` must match the registered id. A detector must not be able to emit a
     result attributed to a different detector -- that would corrupt the audit trail
     and let one detector's bug discredit another's findings.
  2. `detector_version` must match the registered version, so an incident always
     records the version that actually ran.
]]
local function check_result(entry, result)
  if type(result) ~= 'table' then
    return false, 'detector returned a ' .. type(result) .. ', not a DetectionResult'
  end
  if result.detector_id ~= entry.id then
    return false, string.format(
      'detector %q returned a result attributed to %q',
      entry.id, tostring(result.detector_id))
  end
  if result.detector_version ~= entry.version then
    return false, string.format(
      'detector %q v%s returned a result claiming v%s',
      entry.id, tostring(entry.version), tostring(result.detector_version))
  end
  if type(result.confidence) ~= 'number' then
    return false, string.format('detector %q returned a non-numeric confidence', entry.id)
  end
  return true, nil
end

function Registry:_note_error(entry, err, errors)
  local st = self._stats[entry.id]
  st.errors_n = st.errors_n + 1
  st.consecutive_n = st.consecutive_n + 1
  errors[#errors + 1] = { detector_id = entry.id, err = err }
  if st.consecutive_n >= self._max_failures and not st.tripped then
    st.tripped = true
    st.trip_reason = string.format(
      'disabled after %d consecutive failures; last error: %s',
      st.consecutive_n, tostring(err))
  end
end

function Registry:_note_success(entry, n)
  local st = self._stats[entry.id]
  st.results_n = st.results_n + n
  st.consecutive_n = 0     -- an intermittent fault must not accumulate towards a trip
end

--- Run every enabled 'record' detector against one telemetry record.
-- @return results table, errors table
function Registry:run_record(state, record, config)
  local results, errors = {}, {}
  for _, entry in ipairs(self._detectors) do
    if entry.kind == M.KIND_RECORD and is_runnable(self, entry, config) then
      local st = self._stats[entry.id]
      st.runs_n = st.runs_n + 1
      local ok, out = pcall(entry.fn, state, record, config)
      if not ok then
        self:_note_error(entry, tostring(out), errors)
      elseif out == nil then
        self:_note_success(entry, 0)    -- the normal case: no detection
      else
        local valid, verr = check_result(entry, out)
        if valid then
          results[#results + 1] = out
          self:_note_success(entry, 1)
        else
          self:_note_error(entry, verr, errors)
        end
      end
    end
  end
  return results, errors
end

--- Run every enabled 'periodic' detector against a context.
-- @return results table, errors table
function Registry:run_periodic(context, config)
  local results, errors = {}, {}
  for _, entry in ipairs(self._detectors) do
    if entry.kind == M.KIND_PERIODIC and is_runnable(self, entry, config) then
      local st = self._stats[entry.id]
      st.runs_n = st.runs_n + 1
      local ok, out = pcall(entry.fn, context, config)
      if not ok then
        self:_note_error(entry, tostring(out), errors)
      elseif out == nil then
        self:_note_success(entry, 0)
      elseif type(out) ~= 'table' then
        self:_note_error(entry, 'periodic detector must return a list of results', errors)
      else
        local accepted = 0
        local rejected = nil
        for _, r in ipairs(out) do
          local valid, verr = check_result(entry, r)
          if valid then
            results[#results + 1] = r
            accepted = accepted + 1
          else
            rejected = verr
          end
        end
        if rejected then
          self:_note_error(entry, rejected, errors)
        else
          self:_note_success(entry, accepted)
        end
      end
    end
  end
  return results, errors
end

--- Per-detector statistics, including whether a circuit breaker has tripped.
function Registry:stats()
  local out = {}
  for _, entry in ipairs(self._detectors) do
    local st = self._stats[entry.id]
    out[#out + 1] = {
      id = entry.id, version = entry.version, kind = entry.kind,
      enabled = entry.enabled,
      runs_n = st.runs_n, results_n = st.results_n, errors_n = st.errors_n,
      tripped = st.tripped, trip_reason = st.trip_reason,
    }
  end
  return out
end

--- Reset a tripped breaker, e.g. after the detector has been fixed and reloaded.
function Registry:reset(id)
  local st = self._stats[id]
  if not st then return false, 'no such detector' end
  st.tripped, st.trip_reason, st.consecutive_n = false, nil, 0
  return true
end

--[[
  DUAL EXPORT -- see docs/ARCHITECTURE.md §3.2 "Module loading".
]]
SecLab = SecLab or {}
SecLab.registry = M

return M

--[[
  security-forensics / logic / incident.lua

  PURE LUA. The incident model and its lifecycle (docs/DETECTION_MODEL.md §6).

  An incident is a NARRATIVE, not a verdict. It accumulates detections, keeps their
  versions, and records what was considered and rejected. Charter §12 is explicit that
  high confidence is not enforcement, so this module has no path to one.
]]

--[[
  Resolve a sibling module in either environment (see the dual-export note at the
  foot of every pure module). Inside FXServer the sibling is already published on
  the resource-scoped `SecLab` table by an earlier `server_scripts` entry; under
  vanilla Lua in CI it is loaded with `require`.
]]
local function sec_require(key, path)
  if SecLab and SecLab[key] then return SecLab[key] end
  return require(path)
end

local detection = sec_require('detection', 'logic.detection')

local M = {}

M.OBSERVING     = 'OBSERVING'
M.INVESTIGATING = 'INVESTIGATING'
M.CONFIRMED     = 'CONFIRMED'
M.DISMISSED     = 'DISMISSED'
M.RESOLVED      = 'RESOLVED'

--[[
  Allowed transitions. Deliberately restrictive.

  Note what is NOT allowed: CONFIRMED -> DISMISSED. Once an incident has been confirmed
  it is resolved with a resolution note, not quietly un-confirmed -- otherwise the
  audit trail can be rewritten to make a mistake disappear. Reversing a confirmation
  should leave a trace, so it goes CONFIRMED -> RESOLVED with the reason recorded.
]]
local TRANSITIONS = {
  [M.OBSERVING]     = { [M.INVESTIGATING] = true, [M.DISMISSED] = true },
  [M.INVESTIGATING] = { [M.CONFIRMED] = true, [M.DISMISSED] = true, [M.OBSERVING] = true },
  [M.CONFIRMED]     = { [M.RESOLVED] = true },
  [M.DISMISSED]     = { [M.RESOLVED] = true, [M.INVESTIGATING] = true },
  [M.RESOLVED]      = {},
}

M.TRANSITIONS = TRANSITIONS

local Incident = {}
Incident.__index = Incident

--- @param spec { id, player_key, ts, mono, correlation_id }
function M.new(spec)
  assert(type(spec) == 'table', 'incident: spec must be a table')
  assert(type(spec.id) == 'string' and spec.id ~= '', 'incident: id required')
  assert(type(spec.player_key) == 'string' and spec.player_key ~= '',
    'incident: player_key required')

  return setmetatable({
    id             = spec.id,
    player_key     = spec.player_key,
    created_ts     = spec.ts,
    created_mono   = spec.mono,
    correlation_id = spec.correlation_id,
    status         = M.OBSERVING,
    detections     = {},
    notes          = {},
    history        = { { status = M.OBSERVING, ts = spec.ts, mono = spec.mono,
                         note = 'incident opened' } },
    resolution     = nil,
    -- Benign explanations that were considered. Part of the evidence
    -- (docs/FORENSICS role charter): an investigator must see what was ruled out.
    considered     = {},
  }, Incident)
end

--- Add a detection. Returns ok, err.
function Incident:add_detection(result)
  if type(result) ~= 'table' or type(result.detector_id) ~= 'string' then
    return false, 'not a detection result'
  end
  if result.player_key ~= self.player_key then
    return false, string.format('detection player_key %q does not match incident %q',
      tostring(result.player_key), self.player_key)
  end
  if self.status == M.RESOLVED then
    -- A resolved incident is closed history. New evidence opens a new incident that
    -- references this one, rather than mutating a closed record.
    return false, 'cannot add a detection to a RESOLVED incident'
  end
  self.detections[#self.detections + 1] = result
  return true, nil
end

--- Record a benign explanation that was considered, and its outcome.
function Incident:consider(explanation, ruled_out, reason)
  self.considered[#self.considered + 1] = {
    explanation = explanation,
    ruled_out   = ruled_out and true or false,
    reason      = reason,
  }
end

function Incident:note(text, author)
  self.notes[#self.notes + 1] = { text = text, author = author }
end

--- Transition status. Returns ok, err.
function Incident:transition(to, opts)
  opts = opts or {}
  if not TRANSITIONS[self.status] then
    return false, 'incident is in an unknown status: ' .. tostring(self.status)
  end
  if not TRANSITIONS[self.status][to] then
    return false, string.format('transition %s -> %s is not allowed',
      self.status, tostring(to))
  end

  --[[
    CONFIRMED demands a reason. A confirmation with no stated basis is exactly the
    output this project exists to avoid -- it is an accusation, not evidence.
  ]]
  if to == M.CONFIRMED and (type(opts.note) ~= 'string' or #opts.note < 10) then
    return false, 'CONFIRMED requires a note stating the basis for confirmation'
  end
  if to == M.DISMISSED and (type(opts.note) ~= 'string' or #opts.note < 5) then
    -- A dismissal is a labelled false positive and becomes a regression fixture,
    -- so the reason is the valuable part (docs/FALSE_POSITIVE_POLICY.md §3.5).
    return false, 'DISMISSED requires a note explaining the benign cause'
  end

  self.status = to
  self.history[#self.history + 1] = {
    status = to, ts = opts.ts, mono = opts.mono, note = opts.note, author = opts.author,
  }
  if to == M.RESOLVED then
    self.resolution = opts.note or self.resolution
  end
  return true, nil
end

--[[
  Aggregate confidence.

  Phase 3 uses MAX, not a sum. This is deliberate and temporary:

  Summing or otherwise combining confidences requires arguing that the contributing
  detections are INDEPENDENT (docs/DETECTION_MODEL.md §5). Two detectors reading the
  same weaponDamageEvent fields are not independent, and adding them would inflate
  confidence on a single piece of evidence -- manufacturing certainty.

  Proper multi-signal correlation is Phase 5, where independence is argued per pair
  and each weight gets a documented justification. Until then max() is the honest
  answer: the incident is at least as confident as its strongest single detection,
  and claiming more would be arithmetic without a basis.

  Suppressed detections do not contribute.
]]
function Incident:confidence()
  local best = 0.0
  for _, d in ipairs(self.detections) do
    if not detection.is_suppressed(d) and type(d.confidence) == 'number' then
      if d.confidence > best then best = d.confidence end
    end
  end
  return best
end

function Incident:severity()
  local best, rank = nil, 0
  for _, d in ipairs(self.detections) do
    if not detection.is_suppressed(d) then
      local r = detection.severity_rank(d.severity)
      if r > rank then rank, best = r, d.severity end
    end
  end
  return best
end

--- Distinct contributing detectors, with the versions that produced each detection.
-- Versions are kept so an old incident stays readable in the terms of the detector
-- that produced it, even after a threshold is retuned.
function Incident:detector_versions()
  local seen, out = {}, {}
  for _, d in ipairs(self.detections) do
    local key = tostring(d.detector_id) .. '@' .. tostring(d.detector_version)
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = { detector_id = d.detector_id, version = d.detector_version }
    end
  end
  table.sort(out, function(a, b)
    if a.detector_id ~= b.detector_id then return a.detector_id < b.detector_id end
    return (a.version or 0) < (b.version or 0)
  end)
  return out
end

--- Are there at least `n` INDEPENDENT detectors contributing?
-- Independence here is the weak form: distinct detector ids. Real independence
-- (distinct provenance) is argued in Phase 5.
function Incident:distinct_detectors()
  local seen, n = {}, 0
  for _, d in ipairs(self.detections) do
    if not detection.is_suppressed(d) and not seen[d.detector_id] then
      seen[d.detector_id] = true
      n = n + 1
    end
  end
  return n
end

--- Serialisable summary for storage and the dashboard.
function Incident:summary()
  return {
    id                = self.id,
    player_key        = self.player_key,
    created_ts        = self.created_ts,
    status            = self.status,
    confidence        = self:confidence(),
    confidence_basis  = 'max of contributing detections (Phase 3; see logic/incident.lua)',
    severity          = self:severity(),
    detections_n      = #self.detections,
    suppressed_n      = (function()
      local n = 0
      for _, d in ipairs(self.detections) do
        if detection.is_suppressed(d) then n = n + 1 end
      end
      return n
    end)(),
    distinct_detectors_n = self:distinct_detectors(),
    detectors         = self:detector_versions(),
    considered_n      = #self.considered,
    notes_n           = #self.notes,
    resolution        = self.resolution,
    correlation_id    = self.correlation_id,
  }
end


--[[
  DUAL EXPORT -- see docs/ARCHITECTURE.md §3.2 "Module loading".

  FiveM has no documented `require` for resource scripts: every file listed in
  `server_scripts` is loaded as a plain chunk into one shared Lua state, and the
  chunk's return value is DISCARDED. So returning the table is not enough to make
  this module reachable inside FXServer.

  Vanilla Lua 5.4 (the CI tier) is the opposite: it uses the return value and has
  no shared namespace.

  Publishing to a single resource-scoped global satisfies both without an
  environment check. Each resource gets its own Lua state, so `SecLab` does not
  leak between resources.
]]
SecLab = SecLab or {}
SecLab.incident = M

return M

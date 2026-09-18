--[[
  security-forensics / logic / detection.lua

  PURE LUA. The DetectionResult type, and the confidence policy as EXECUTABLE CODE.

  The point of this module: docs/TRUST_BOUNDARY.md §4 and docs/DETECTION_MODEL.md §3
  state confidence caps in prose. Prose is not a control. A detector author under
  pressure to "make it fire" will raise a number, and no reviewer reliably catches that.

  So the caps live here and are applied by construction. A detector cannot claim 0.9
  from attacker-supplied data, because `new()` will clamp it and record why.
]]

local M = {}

M.SEVERITIES = { info = 1, low = 2, medium = 3, high = 4, critical = 5 }

-- Mirrors logic/schema.lua TRUST in security-telemetry. Duplicated deliberately:
-- resources cannot share files, and a silent divergence would be worse than a copy.
M.TRUST = { observed = true, claimed = true, derived = true, framework = true }

--[[
  Cap 1 -- CLAIMED-ONLY.
  A detection resting solely on attacker-chosen payload fields may not exceed 0.5.
  Raising it requires at least one server-`observed` corroboration.
]]
M.CAP_CLAIMED_ONLY = 0.5

--[[
  Cap 2 -- UNCHARACTERISED SOURCE.
  Anything derived from a native whose behaviour has not been measured is capped at 0.3.
  Today that means GET_PLAYER_CAMERA_ROTATION and friends (EXP-001), and the
  weaponDamageEvent fields whose semantics are undocumented (EXP-002).

  This is charter §21 made mechanical: a HYPOTHESIS must not masquerade as evidence.
  When an experiment completes, the source is removed from the set below -- which is a
  deliberate, reviewable, one-line change rather than a quiet threshold edit.
]]
M.CAP_UNCHARACTERISED = 0.3

M.UNCHARACTERISED_SOURCES = {
  ['poll:camera_rotation']        = 'EXP-001: camera native behaviour unmeasured',
  ['event:weaponDamageEvent#damageTime'] = 'EXP-002: damageTime clock base and unit undocumented',
}

local function is_finite_number(v)
  return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

--[[
  Apply the confidence policy.

  @param requested number        what the detector asked for
  @param trust_levels table      trust values of the records the detection rests on
  @param sources table|nil       telemetry `source` strings the detection rests on
  @return confidence number, caps table  (caps lists every cap that bit, with a reason)
]]
function M.apply_caps(requested, trust_levels, sources)
  local caps = {}
  local conf = requested

  if not is_finite_number(conf) then
    return 0.0, { { cap = 'invalid', reason = 'confidence was not a finite number' } }
  end
  if conf < 0 then conf = 0.0 end
  if conf > 1 then
    caps[#caps + 1] = { cap = 'range', reason = 'confidence above 1.0 clamped', limit = 1.0 }
    conf = 1.0
  end

  -- Cap 1: is there any server-observed corroboration?
  local has_observed = false
  local has_any = false
  for _, t in ipairs(trust_levels or {}) do
    has_any = true
    if t == 'observed' or t == 'framework' then has_observed = true end
  end

  -- No declared basis at all is treated as the weakest case, not the strongest.
  -- Failing closed matters more here than convenience for the caller.
  if not has_any then
    if conf > M.CAP_CLAIMED_ONLY then
      caps[#caps + 1] = {
        cap = 'claimed_only', limit = M.CAP_CLAIMED_ONLY,
        reason = 'no trust basis was declared, so the detection is treated as claimed-only',
      }
      conf = M.CAP_CLAIMED_ONLY
    end
  elseif not has_observed then
    if conf > M.CAP_CLAIMED_ONLY then
      caps[#caps + 1] = {
        cap = 'claimed_only', limit = M.CAP_CLAIMED_ONLY,
        reason = 'detection rests only on client-supplied data; '
              .. 'raising confidence requires an observed corroboration',
      }
      conf = M.CAP_CLAIMED_ONLY
    end
  end

  -- Cap 2: any uncharacterised source in the basis?
  for _, s in ipairs(sources or {}) do
    local why = M.UNCHARACTERISED_SOURCES[s]
    if why and conf > M.CAP_UNCHARACTERISED then
      caps[#caps + 1] = {
        cap = 'uncharacterised', limit = M.CAP_UNCHARACTERISED,
        reason = why, source = s,
      }
      conf = M.CAP_UNCHARACTERISED
    end
  end

  return conf, caps
end

--[[
  Construct a DetectionResult.

  spec = {
    detector_id, detector_version, player_key, ts, mono,
    signal, measurements, confidence, severity,
    evidence_refs  = { 'c_9f2a1b', ... },
    trust_levels   = { 'claimed', 'observed' },
    sources        = { 'event:weaponDamageEvent', 'poll:entity_state' },
    explanation    = '...',
    context        = { ... },
    suppressed_by  = 'network:packet_loss',   -- optional, see docs/FALSE_POSITIVE_POLICY.md
  }

  @return result table|nil, errors table
]]
function M.new(spec)
  local errs = {}
  local function err(fmt, ...) errs[#errs + 1] = string.format(fmt, ...) end

  if type(spec) ~= 'table' then return nil, { 'spec must be a table' } end

  for _, f in ipairs({ 'detector_id', 'signal', 'player_key', 'explanation' }) do
    if type(spec[f]) ~= 'string' or spec[f] == '' then
      err('%s must be a non-empty string', f)
    end
  end
  if type(spec.detector_version) ~= 'number' or spec.detector_version < 1 then
    err('detector_version must be a positive number')
  end
  if not is_finite_number(spec.mono) then err('mono must be a finite number') end
  if not is_finite_number(spec.ts) then err('ts must be a finite number') end
  if not M.SEVERITIES[spec.severity or ''] then
    err('severity %q is not one of info/low/medium/high/critical', tostring(spec.severity))
  end

  --[[
    An explanation must let a human answer "why" without reading the code
    (docs/DETECTION_MODEL.md §2). A result whose explanation reads "score 0.87" is
    not evidence of anything, so a minimum length is enforced. It is a crude proxy
    for substance, but a cheap one that catches the placeholder case.
  ]]
  if type(spec.explanation) == 'string' and #spec.explanation < 30 then
    err('explanation is too short to be evidence (%d chars); state what was observed, '
      .. 'what was claimed, and why that is notable', #spec.explanation)
  end

  for _, t in ipairs(spec.trust_levels or {}) do
    if not M.TRUST[t] then err('unknown trust level %q in trust_levels', tostring(t)) end
  end

  if type(spec.measurements) == 'table' then
    for k, v in pairs(spec.measurements) do
      if type(k) ~= 'string' then
        err('measurement key must be a string')
      elseif not is_finite_number(v) then
        err('measurement %q must be a finite number', tostring(k))
      end
    end
  end

  if #errs > 0 then return nil, errs end

  local confidence, caps = M.apply_caps(spec.confidence, spec.trust_levels, spec.sources)

  local trust_basis = {}
  for _, t in ipairs(spec.trust_levels or {}) do trust_basis[#trust_basis + 1] = t end
  table.sort(trust_basis)

  return {
    detector_id      = spec.detector_id,
    detector_version = spec.detector_version,
    player_key       = spec.player_key,
    ts               = spec.ts,
    mono             = spec.mono,
    signal           = spec.signal,
    measurements     = spec.measurements or {},
    confidence       = confidence,
    confidence_requested = spec.confidence,
    confidence_caps  = caps,            -- empty when nothing was capped
    severity         = spec.severity,
    evidence_refs    = spec.evidence_refs or {},
    trust_basis      = trust_basis,
    sources          = spec.sources or {},
    explanation      = spec.explanation,
    context          = spec.context or {},
    suppressed_by    = spec.suppressed_by,
  }, {}
end

--- Was this detection suppressed by a benign explanation?
-- Suppressed detections are still RECORDED (docs/FALSE_POSITIVE_POLICY.md §3.4):
-- suppression counts are how tuning gets measured, and a detector suppressed 99% of
-- the time is telling you something important.
function M.is_suppressed(result)
  return result ~= nil and result.suppressed_by ~= nil
end

function M.severity_rank(sev) return M.SEVERITIES[sev or ''] or 0 end


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
SecLab.detection = M

return M

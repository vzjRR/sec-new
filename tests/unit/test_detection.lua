--[[
  tests/unit/test_detection.lua

  These tests exist because docs/TRUST_BOUNDARY.md §4 and DETECTION_MODEL.md §3 state
  confidence caps in PROSE, and prose is not a control. The caps are enforced by
  construction here, so a detector cannot claim high confidence from attacker-supplied
  data even if its author wants to.
]]
local H = ...
local detection = require('logic.detection')

local function spec(over)
  local s = {
    detector_id = 'combat.dead_shooter', detector_version = 1,
    player_key = 'QB:ABCD1234', ts = 1758204000123, mono = 154321,
    signal = 'shot_while_dead', severity = 'medium', confidence = 0.4,
    measurements = { gap_ms = 420, shots_n = 3 },
    trust_levels = { 'claimed', 'observed' },
    sources = { 'event:weaponDamageEvent', 'poll:entity_state' },
    evidence_refs = { 'c_9f2a1b' },
    explanation = 'Three weapon damage claims arrived 420ms after the server observed '
               .. 'this ped as dead.',
  }
  for k, v in pairs(over or {}) do
    if v == '__nil__' then s[k] = nil else s[k] = v end
  end
  return s
end

H.suite('detection: construction')

H.test('a well-formed spec produces a result', function()
  local r, errs = detection.new(spec())
  H.ok(r, table.concat(errs or {}, '; '))
  H.eq(r.detector_id, 'combat.dead_shooter')
  H.eq(r.confidence, 0.4)
  H.eq(#r.confidence_caps, 0, 'nothing should have been capped')
end)

H.test('rejects a non-table spec', function()
  local r, errs = detection.new('nope')
  H.is_nil(r); H.rejects(false, errs, 'must be a table')
end)

H.test('requires the identifying fields', function()
  for _, f in ipairs({ 'detector_id', 'signal', 'player_key', 'explanation' }) do
    local r, errs = detection.new(spec{ [f] = '__nil__' })
    H.is_nil(r, f .. ' should be required')
    H.rejects(false, errs, f)
  end
end)

H.test('requires a positive detector_version', function()
  -- Versions are what keep an old incident readable after a threshold is retuned.
  H.is_nil((detection.new(spec{ detector_version = 0 })))
  H.is_nil((detection.new(spec{ detector_version = '__nil__' })))
end)

H.test('rejects an unknown severity', function()
  local r, errs = detection.new(spec{ severity = 'catastrophic' })
  H.is_nil(r); H.rejects(false, errs, 'severity')
end)

H.test('rejects a non-finite measurement', function()
  H.is_nil((detection.new(spec{ measurements = { x_n = 0/0 } })))
  H.is_nil((detection.new(spec{ measurements = { x_n = math.huge } })))
end)

H.test('rejects an unknown trust level', function()
  local r, errs = detection.new(spec{ trust_levels = { 'vibes' } })
  H.is_nil(r); H.rejects(false, errs, 'unknown trust level')
end)

H.suite('detection: the explanation must be evidence')

H.test('rejects a placeholder explanation', function()
  -- "score 0.87" is not evidence of anything.
  local r, errs = detection.new(spec{ explanation = 'score 0.87' })
  H.is_nil(r)
  H.rejects(false, errs, 'too short to be evidence')
end)

H.test('accepts a substantive explanation', function()
  H.ok((detection.new(spec{ explanation =
    'Claimed damage exceeded the observed health delta by 40 points over 5 shots.' })))
end)

H.suite('detection: CAP 1 -- claimed-only <= 0.5')

H.test('caps a claimed-only detection at 0.5', function()
  local r = detection.new(spec{ trust_levels = { 'claimed' }, confidence = 0.95 })
  H.eq(r.confidence, 0.5)
  H.eq(r.confidence_requested, 0.95, 'the request must be preserved for audit')
  H.eq(#r.confidence_caps, 1)
  H.eq(r.confidence_caps[1].cap, 'claimed_only')
  H.ok(r.confidence_caps[1].reason:find('observed corroboration', 1, true))
end)

H.test('does not cap when an observed signal corroborates', function()
  local r = detection.new(spec{ trust_levels = { 'claimed', 'observed' }, confidence = 0.85 })
  H.eq(r.confidence, 0.85)
  H.eq(#r.confidence_caps, 0)
end)

H.test('framework trust counts as corroboration', function()
  local r = detection.new(spec{ trust_levels = { 'claimed', 'framework' }, confidence = 0.8 })
  H.eq(r.confidence, 0.8)
end)

H.test('derived-only does NOT lift the cap', function()
  -- `derived` is computed from other records; on its own it does not establish that
  -- anything was server-observed.
  local r = detection.new(spec{ trust_levels = { 'claimed', 'derived' }, confidence = 0.9 })
  H.eq(r.confidence, 0.5)
end)

H.test('an undeclared trust basis fails CLOSED, not open', function()
  -- Omitting trust_levels must not be a way to bypass the cap.
  local r = detection.new(spec{ trust_levels = '__nil__', confidence = 0.99 })
  H.eq(r.confidence, 0.5)
  H.ok(r.confidence_caps[1].reason:find('no trust basis', 1, true))
end)

H.test('a low claimed-only confidence passes through unchanged', function()
  local r = detection.new(spec{ trust_levels = { 'claimed' }, confidence = 0.2 })
  H.eq(r.confidence, 0.2)
  H.eq(#r.confidence_caps, 0)
end)

H.suite('detection: CAP 2 -- uncharacterised sources <= 0.3')

H.test('caps a detection built on the camera natives (EXP-001)', function()
  -- charter §21 made mechanical: a HYPOTHESIS must not masquerade as evidence.
  local r = detection.new(spec{
    trust_levels = { 'observed' },
    sources = { 'poll:camera_rotation' },
    confidence = 0.9,
  })
  H.eq(r.confidence, 0.3)
  local found = false
  for _, c in ipairs(r.confidence_caps) do
    if c.cap == 'uncharacterised' then
      found = true
      H.ok(c.reason:find('EXP-001', 1, true), 'the cap must name the blocking experiment')
    end
  end
  H.ok(found, 'expected an uncharacterised cap')
end)

H.test('caps damageTime-derived detections (EXP-002)', function()
  local r = detection.new(spec{
    trust_levels = { 'observed' },
    sources = { 'event:weaponDamageEvent#damageTime' },
    confidence = 0.8,
  })
  H.eq(r.confidence, 0.3)
end)

H.test('the stricter cap wins when both apply', function()
  local r = detection.new(spec{
    trust_levels = { 'claimed' },
    sources = { 'poll:camera_rotation' },
    confidence = 1.0,
  })
  H.eq(r.confidence, 0.3, 'uncharacterised (0.3) is stricter than claimed-only (0.5)')
  H.eq(#r.confidence_caps, 2, 'both caps should be recorded for audit')
end)

H.test('a characterised source is not capped', function()
  local r = detection.new(spec{
    trust_levels = { 'observed' }, sources = { 'poll:entity_state' }, confidence = 0.9,
  })
  H.eq(r.confidence, 0.9)
end)

H.suite('detection: confidence range')

H.test('clamps above 1.0 and records it', function()
  local r = detection.new(spec{ trust_levels = { 'observed' }, confidence = 1.7 })
  H.eq(r.confidence, 1.0)
  H.eq(r.confidence_caps[1].cap, 'range')
end)

H.test('clamps below 0', function()
  local r = detection.new(spec{ trust_levels = { 'observed' }, confidence = -0.5 })
  H.eq(r.confidence, 0.0)
end)

H.test('a non-numeric confidence becomes 0 and is flagged', function()
  local c, caps = detection.apply_caps('high', { 'observed' }, {})
  H.eq(c, 0.0)
  H.eq(caps[1].cap, 'invalid')
end)

H.suite('detection: suppression')

H.test('a suppressed detection is recorded, not discarded', function()
  -- Suppression counts are how tuning gets measured
  -- (docs/FALSE_POSITIVE_POLICY.md §3.4).
  local r = detection.new(spec{ suppressed_by = 'network:packet_loss' })
  H.ok(r)
  H.eq(detection.is_suppressed(r), true)
  H.eq(r.suppressed_by, 'network:packet_loss')
end)

H.test('an unsuppressed detection reports as such', function()
  H.eq(detection.is_suppressed(detection.new(spec())), false)
end)

H.test('is_suppressed tolerates nil', function()
  H.eq(detection.is_suppressed(nil), false)
end)

H.suite('detection: severity ranking')

H.test('ranks severities in order', function()
  local prev = 0
  for _, s in ipairs({ 'info', 'low', 'medium', 'high', 'critical' }) do
    local r = detection.severity_rank(s)
    H.ok(r > prev, s .. ' should rank above the previous')
    prev = r
  end
end)

H.test('an unknown severity ranks 0', function()
  H.eq(detection.severity_rank('nonsense'), 0)
  H.eq(detection.severity_rank(nil), 0)
end)

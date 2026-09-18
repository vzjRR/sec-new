--[[
  tests/unit/test_investigation.lua

  The bundle must pass the FORENSICS_ENGINEER standard: given an incident, a human can
  reconstruct what happened, what was observed vs claimed, which detector versions
  concluded what, which benign causes were ruled out, and WHAT IS MISSING.

  The last two get skipped in practice, and they are what separates evidence from an
  accusation. So these tests focus on `review()` refusing to bless a bundle that omits
  them.
]]
local H = ...
local investigation = require('logic.investigation')
local incident_lib  = require('logic.incident')
local detection     = require('logic.detection')

local function det(over)
  local s = {
    detector_id = 'events.contract', detector_version = 2,
    player_key = 'QB:ABCD1234', ts = 1, mono = 100,
    signal = 'arity_violation', severity = 'medium', confidence = 0.4,
    trust_levels = { 'observed' }, sources = { 'event:netEvent' },
    explanation = 'A net event was called with 2 arguments where the contract requires 3.',
  }
  for k, v in pairs(over or {}) do s[k] = v end
  local r, errs = detection.new(s)
  assert(r, table.concat(errs or {}, '; '))
  return r
end

local function rec(seq, mono, trust, over)
  local r = {
    seq = seq, mono = mono, ts = 1758204000000 + mono, player_key = 'QB:ABCD1234',
    category = 'event', event = 'net_event', source = 'event:netEvent',
    trust = trust, measurements = {}, context = {},
  }
  for k, v in pairs(over or {}) do r[k] = v end
  return r
end

local function inc()
  return incident_lib.new{ id = 'INC-001', player_key = 'QB:ABCD1234', ts = 1, mono = 100 }
end

H.suite('investigation: bundle assembly')

H.test('requires an incident', function()
  H.eq(pcall(investigation.build, nil, {}), false)
  H.eq(pcall(investigation.build, { not_an_incident = true }, {}), false)
end)

H.test('assembles incident, detections, timeline and trust', function()
  local i = inc()
  i:add_detection(det())
  local b = investigation.build(i, { rec(1, 100, 'observed'), rec(2, 200, 'claimed') })
  H.eq(b.incident.id, 'INC-001')
  H.eq(#b.detections, 1)
  H.eq(b.timeline.stats.records_n, 2)
  H.eq(b.trust.observed_n, 1)
  H.eq(b.trust.claimed_n, 1)
end)

H.test('carries detector versions through to the bundle', function()
  local i = inc()
  i:add_detection(det{ detector_version = 7 })
  local b = investigation.build(i, {})
  H.eq(b.detections[1].detector_version, 7)
end)

H.test('surfaces applied confidence caps', function()
  -- A cap is part of the story: it says the evidence did not support what the
  -- detector initially asked for.
  local i = inc()
  i:add_detection(det{ trust_levels = { 'claimed' }, confidence = 0.95 })
  local b = investigation.build(i, {})
  H.eq(b.detections[1].confidence, 0.5)
  H.eq(b.detections[1].confidence_requested, 0.95)
  H.eq(#b.detections[1].confidence_caps, 1)
end)

H.suite('investigation: review refuses to bless a weak bundle')

H.test('a complete, corroborated, considered bundle is reviewable', function()
  local i = inc()
  i:add_detection(det())
  i:add_detection(det{ detector_id = 'entity.rate' })
  i:consider('packet loss', true, 'loss was 0.1% in this window')
  i:transition(incident_lib.INVESTIGATING)
  i:transition(incident_lib.CONFIRMED, { note = 'two independent signals, network ruled out' })
  local b = investigation.build(i, { rec(1, 100, 'observed'), rec(2, 200, 'claimed') },
    { store_complete = true })
  H.eq(b.review.reviewable, true,
    'unexpected problems: ' .. (b.review.problems[1] and b.review.problems[1].code or ''))
end)

H.test('CONFIRMED with no observed record is flagged CRITICAL', function()
  --[[
    A confirmation resting entirely on client claims is not evidence -- the attacker
    supplied every value it rests on. This is the single most important check here.
  ]]
  local i = inc()
  i:add_detection(det{ trust_levels = { 'claimed' } })
  i:consider('lag', true, 'ping was 20ms')
  i:transition(incident_lib.INVESTIGATING)
  i:transition(incident_lib.CONFIRMED, { note = 'claims look impossible to me' })
  local b = investigation.build(i, { rec(1, 100, 'claimed'), rec(2, 200, 'claimed') },
    { store_complete = true })
  H.eq(b.review.reviewable, false)
  H.eq(b.review.worst, 'critical')
  local found = false
  for _, p in ipairs(b.review.problems) do
    if p.code == 'confirmed_without_observation' then found = true end
  end
  H.ok(found, 'expected confirmed_without_observation')
end)

H.test('CONFIRMED with no benign cause considered is flagged', function()
  -- An investigator cannot tell whether the obvious alternatives were ruled out or
  -- never examined.
  local i = inc()
  i:add_detection(det())
  i:transition(incident_lib.INVESTIGATING)
  i:transition(incident_lib.CONFIRMED, { note = 'strong signal on the wire' })
  local b = investigation.build(i, { rec(1, 100, 'observed') }, { store_complete = true })
  local found = false
  for _, p in ipairs(b.review.problems) do
    if p.code == 'no_benign_causes_considered' then found = true end
  end
  H.ok(found, 'expected no_benign_causes_considered')
end)

H.test('a gapped timeline blocks the bundle', function()
  local i = inc()
  i:add_detection(det())
  local b = investigation.build(i, { rec(1, 100, 'observed'), rec(9, 900, 'observed') },
    { store_complete = true })
  H.eq(b.review.reviewable, false)
  local found = false
  for _, p in ipairs(b.review.problems) do
    if p.code == 'incomplete_timeline' then found = true; H.eq(p.severity, 'high') end
  end
  H.ok(found, 'a gap in the record must block a conclusion, not be footnoted')
end)

H.test('an incomplete evidence store blocks the bundle', function()
  local i = inc()
  i:add_detection(det())
  local b = investigation.build(i, { rec(1, 100, 'observed') },
    { store_complete = false, store_note = '3 writes failed' })
  local found = false
  for _, p in ipairs(b.review.problems) do
    if p.code == 'incomplete_store' then found = true; H.ok(p.detail:find('3 writes')) end
  end
  H.ok(found, 'expected incomplete_store')
end)

H.test('a single detector carrying a high-confidence conclusion is flagged', function()
  -- Correlation across independent signals is Phase 5; until then a single-source
  -- finding must be labelled as one.
  local i = inc()
  i:add_detection(det{ trust_levels = { 'observed' }, confidence = 0.85 })
  i:consider('lag', true, 'ping 20ms')
  local b = investigation.build(i, { rec(1, 100, 'observed') }, { store_complete = true })
  local found = false
  for _, p in ipairs(b.review.problems) do
    if p.code == 'single_detector_high_confidence' then found = true end
  end
  H.ok(found, 'expected single_detector_high_confidence')
end)

H.test('an incident with no detections is flagged', function()
  local b = investigation.build(inc(), { rec(1, 100, 'observed') }, { store_complete = true })
  local found = false
  for _, p in ipairs(b.review.problems) do
    if p.code == 'no_detections' then found = true end
  end
  H.ok(found)
end)

H.test('problems are ordered worst first', function()
  local i = inc()
  i:add_detection(det{ trust_levels = { 'claimed' } })
  i:transition(incident_lib.INVESTIGATING)
  i:transition(incident_lib.CONFIRMED, { note = 'a confirmation with weak support' })
  local b = investigation.build(i, { rec(1, 100, 'claimed'), rec(9, 900, 'claimed') },
    { store_complete = false })
  local rank = { critical = 4, high = 3, medium = 2, low = 1 }
  for k = 2, #b.review.problems do
    H.ok(rank[b.review.problems[k-1].severity] >= rank[b.review.problems[k].severity],
      'severity must not increase down the list')
  end
  H.eq(b.review.worst, 'critical')
end)

H.suite('investigation: rendering')

H.test('renders the sections an investigator needs', function()
  local i = inc()
  i:add_detection(det())
  i:consider('admin teleport', true, 'no ACE permission')
  local b = investigation.build(i, { rec(1, 100, 'observed'), rec(3, 300, 'claimed') },
    { store_complete = true })
  local text = investigation.render(b)
  for _, needle in ipairs({
    'INCIDENT INC-001', 'QB:ABCD1234', 'TRUST BASIS', 'DETECTIONS',
    'BENIGN CAUSES CONSIDERED', 'admin teleport', 'TIMELINE', 'REVIEW',
  }) do
    H.ok(text:find(needle, 1, true), 'render omitted ' .. needle)
  end
end)

H.test('rendering shows a gap inline in the timeline', function()
  local i = inc()
  i:add_detection(det())
  local b = investigation.build(i, { rec(1, 100, 'observed'), rec(5, 500, 'observed') })
  local text = investigation.render(b)
  H.ok(text:find('GAP', 1, true), 'the gap must be visible in the rendered timeline')
  H.ok(text:find('missing', 1, true))
end)

H.test('rendering shows an applied cap and its reason', function()
  local i = inc()
  i:add_detection(det{ trust_levels = { 'claimed' }, confidence = 0.95 })
  local text = investigation.render(investigation.build(i, {}))
  H.ok(text:find('capped', 1, true))
  H.ok(text:find('observed corroboration', 1, true))
end)

H.test('rendering marks a suppressed detection', function()
  local i = inc()
  i:add_detection(det{ suppressed_by = 'network:packet_loss' })
  local text = investigation.render(investigation.build(i, {}))
  H.ok(text:find('SUPPRESSED', 1, true))
  H.ok(text:find('packet_loss', 1, true))
end)

H.test('rendering never crashes on a sparse or malformed bundle', function()
  --[[
    A render that throws is worst precisely when it matters: while someone reviews a
    disputed conclusion. An earlier version indexed `review.problems` without a nil
    guard and crashed on an empty bundle, so every shape is exercised here.
  ]]
  for i, bundle in ipairs({
    {},
    { incident = {} },
    { detections = {} },
    { detections = { {} } },                 -- a detection with no fields at all
    { timeline = {} },
    { timeline = { entries = { { kind = 'gap' } } } },
    { trust = {} },
    { review = {} },                          -- review present but empty
    { review = { problems = {} } },
    { considered = { {} } },
    { incident = { id = 'X' }, status = 'CONFIRMED' },
  }) do
    local ok, err = pcall(investigation.render, bundle)
    H.ok(ok, ('render crashed on malformed bundle %d: %s'):format(i, tostring(err)))
    if ok then H.ok(type(err) == 'string' and #err > 0, 'render returned nothing') end
  end
end)

H.test('an unassessed bundle says so rather than claiming to be clean', function()
  -- "no problems found" and "never checked" must not look the same.
  local text = investigation.render({ incident = { id = 'X' } })
  H.ok(text:find('not assessed', 1, true), 'got: ' .. text:sub(-120))
end)

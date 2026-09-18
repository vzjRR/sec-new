--[[
  tests/unit/test_incident.lua
  The incident is a narrative, not a verdict. These tests pin the properties that keep
  it honest: no un-confirming, reasons required, and no unjustified confidence maths.
]]
local H = ...
local incident  = require('logic.incident')
local detection = require('logic.detection')

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

local function inc()
  return incident.new{ id = 'INC-001', player_key = 'QB:ABCD1234', ts = 1, mono = 100 }
end

H.suite('incident: creation')

H.test('opens in OBSERVING with history', function()
  local i = inc()
  H.eq(i.status, incident.OBSERVING)
  H.eq(#i.history, 1)
  H.eq(i.history[1].status, incident.OBSERVING)
end)

H.test('requires id and player_key', function()
  H.eq(pcall(incident.new, { player_key = 'QB:A' }), false)
  H.eq(pcall(incident.new, { id = 'X' }), false)
  H.eq(pcall(incident.new, 'nope'), false)
end)

H.suite('incident: detections')

H.test('accepts a matching detection', function()
  local i = inc()
  local ok, err = i:add_detection(det())
  H.eq(ok, true); H.is_nil(err)
  H.eq(#i.detections, 1)
end)

H.test('rejects a detection for a different player', function()
  -- Cross-contaminating incidents would attribute one player's evidence to another.
  local i = inc()
  local ok, err = i:add_detection(det{ player_key = 'QB:OTHER999' })
  H.eq(ok, false)
  H.ok(err:find('does not match', 1, true))
end)

H.test('rejects a non-detection', function()
  H.eq((inc():add_detection({ nonsense = true })), false)
  H.eq((inc():add_detection(nil)), false)
end)

H.suite('incident: lifecycle transitions')

H.test('OBSERVING to INVESTIGATING is allowed', function()
  local i = inc()
  H.eq((i:transition(incident.INVESTIGATING)), true)
  H.eq(i.status, incident.INVESTIGATING)
end)

H.test('OBSERVING cannot jump straight to CONFIRMED', function()
  local i = inc()
  local ok, err = i:transition(incident.CONFIRMED, { note = 'skipping ahead here' })
  H.eq(ok, false)
  H.ok(err:find('not allowed', 1, true))
end)

H.test('CONFIRMED requires a note stating the basis', function()
  -- A confirmation with no stated basis is an accusation, not evidence.
  local i = inc()
  i:transition(incident.INVESTIGATING)
  local ok, err = i:transition(incident.CONFIRMED)
  H.eq(ok, false)
  H.ok(err:find('requires a note', 1, true))
  H.eq((i:transition(incident.CONFIRMED,
    { note = 'three independent signals, network ruled out' })), true)
  H.eq(i.status, incident.CONFIRMED)
end)

H.test('DISMISSED requires a note explaining the benign cause', function()
  -- A dismissal becomes a regression fixture; the reason is the valuable part.
  local i = inc()
  local ok, err = i:transition(incident.DISMISSED)
  H.eq(ok, false)
  H.ok(err:find('benign cause', 1, true))
  H.eq((i:transition(incident.DISMISSED, { note = 'admin teleport, confirmed via ACE' })), true)
end)

H.test('CONFIRMED cannot be quietly un-confirmed', function()
  -- Reversing a confirmation must leave a trace: CONFIRMED -> RESOLVED with a reason,
  -- never CONFIRMED -> DISMISSED, which would erase the mistake from the audit trail.
  local i = inc()
  i:transition(incident.INVESTIGATING)
  i:transition(incident.CONFIRMED, { note = 'strong multi-signal evidence' })
  H.eq((i:transition(incident.DISMISSED, { note = 'actually fine' })), false)
  H.eq((i:transition(incident.OBSERVING)), false)
  H.eq((i:transition(incident.RESOLVED, { note = 'confirmation withdrawn: detector v2 bug' })), true)
  H.eq(i.resolution, 'confirmation withdrawn: detector v2 bug')
end)

H.test('RESOLVED is terminal', function()
  local i = inc()
  i:transition(incident.DISMISSED, { note = 'lag spike' })
  i:transition(incident.RESOLVED, { note = 'closed' })
  for _, s in ipairs({ incident.OBSERVING, incident.INVESTIGATING,
                       incident.CONFIRMED, incident.DISMISSED }) do
    H.eq((i:transition(s, { note = 'trying to reopen a closed record' })), false, s)
  end
end)

H.test('a dismissed incident can be reopened when new evidence arrives', function()
  local i = inc()
  i:transition(incident.DISMISSED, { note = 'looked like lag' })
  H.eq((i:transition(incident.INVESTIGATING)), true)
end)

H.test('no detection can be added to a RESOLVED incident', function()
  -- New evidence opens a new incident referencing this one, rather than mutating
  -- closed history.
  local i = inc()
  i:transition(incident.DISMISSED, { note = 'benign' })
  i:transition(incident.RESOLVED, { note = 'closed' })
  local ok, err = i:add_detection(det())
  H.eq(ok, false)
  H.ok(err:find('RESOLVED', 1, true))
end)

H.test('every transition is recorded in history', function()
  local i = inc()
  i:transition(incident.INVESTIGATING, { note = 'escalating', author = 'analyst' })
  i:transition(incident.CONFIRMED, { note = 'confirmed on three signals' })
  H.eq(#i.history, 3)
  H.eq(i.history[2].author, 'analyst')
  H.eq(i.history[3].status, incident.CONFIRMED)
end)

H.suite('incident: confidence uses MAX, not a sum')

H.test('reports the strongest single detection', function()
  local i = inc()
  i:add_detection(det{ confidence = 0.3 })
  i:add_detection(det{ detector_id = 'entity.rate', confidence = 0.45 })
  H.near(i:confidence(), 0.45, 1e-9)
end)

H.test('does NOT sum confidences', function()
  --[[
    Summing would require arguing that the detections are independent
    (docs/DETECTION_MODEL.md §5). Two detectors reading the same event fields are not,
    and adding them manufactures certainty from one piece of evidence. Phase 5 does
    this properly; until then max() is the honest answer.
  ]]
  local i = inc()
  i:add_detection(det{ confidence = 0.4 })
  i:add_detection(det{ detector_id = 'b', confidence = 0.4 })
  i:add_detection(det{ detector_id = 'c', confidence = 0.4 })
  H.near(i:confidence(), 0.4, 1e-9, 'three 0.4 signals must not become 1.2 or 0.78')
end)

H.test('suppressed detections do not contribute confidence', function()
  local i = inc()
  i:add_detection(det{ confidence = 0.45, suppressed_by = 'network:packet_loss' })
  H.eq(i:confidence(), 0.0)
end)

H.test('an empty incident has zero confidence', function()
  H.eq(inc():confidence(), 0.0)
end)

H.suite('incident: severity and detectors')

H.test('reports the highest severity among unsuppressed detections', function()
  local i = inc()
  i:add_detection(det{ severity = 'low' })
  i:add_detection(det{ detector_id = 'b', severity = 'high' })
  i:add_detection(det{ detector_id = 'c', severity = 'medium' })
  H.eq(i:severity(), 'high')
end)

H.test('records detector versions so old incidents stay readable', function()
  local i = inc()
  i:add_detection(det{ detector_id = 'a', detector_version = 1 })
  i:add_detection(det{ detector_id = 'a', detector_version = 3 })
  i:add_detection(det{ detector_id = 'b', detector_version = 1 })
  local v = i:detector_versions()
  H.eq(#v, 3, 'the same detector at two versions counts as two entries')
  H.eq(v[1].detector_id, 'a'); H.eq(v[1].version, 1)
  H.eq(v[2].version, 3)
end)

H.test('counts distinct contributing detectors', function()
  local i = inc()
  i:add_detection(det{ detector_id = 'a' })
  i:add_detection(det{ detector_id = 'a', detector_version = 2 })
  i:add_detection(det{ detector_id = 'b' })
  H.eq(i:distinct_detectors(), 2)
end)

H.suite('incident: what was considered and rejected')

H.test('records benign explanations that were ruled out', function()
  -- An investigator must see what was considered, not just the conclusion.
  local i = inc()
  i:consider('admin teleport', true, 'player has no ACE permission')
  i:consider('packet loss', false, 'loss was 0.2% in this window')
  H.eq(#i.considered, 2)
  H.eq(i.considered[1].ruled_out, true)
  H.eq(i.considered[2].ruled_out, false)
end)

H.test('analyst notes are kept', function()
  local i = inc()
  i:note('reviewed the timeline', 'vzjRR')
  H.eq(i.notes[1].author, 'vzjRR')
end)

H.suite('incident: summary')

H.test('summary states the basis of its confidence figure', function()
  local i = inc()
  i:add_detection(det{ confidence = 0.4 })
  local s = i:summary()
  H.eq(s.detections_n, 1)
  H.eq(s.distinct_detectors_n, 1)
  H.ok(s.confidence_basis:find('max', 1, true),
    'the summary must say how confidence was derived, not just give a number')
end)

H.test('summary counts suppressed detections separately', function()
  local i = inc()
  i:add_detection(det{ confidence = 0.4 })
  i:add_detection(det{ detector_id = 'b', suppressed_by = 'network:ping' })
  local s = i:summary()
  H.eq(s.detections_n, 2)
  H.eq(s.suppressed_n, 1)
  H.eq(s.distinct_detectors_n, 1, 'suppressed detectors do not count as contributing')
end)

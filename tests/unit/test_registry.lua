--[[
  tests/unit/test_registry.lua

  The registry's job is containment: a broken or misbehaving detector must not be able
  to crash the pipeline, corrupt the audit trail, or degrade observability forever.
  These tests attack each of those.
]]
local H = ...
local registry  = require('logic.registry')
local detection = require('logic.detection')

local function reg(opts)
  return registry.new({ detection_new = detection.new }, opts)
end

local function result_for(id, version, over)
  local s = {
    detector_id = id, detector_version = version or 1,
    player_key = 'QB:ABCD1234', ts = 1, mono = 100,
    signal = 'sig', severity = 'low', confidence = 0.2,
    trust_levels = { 'observed' }, sources = { 'poll:entity_state' },
    explanation = 'A sufficiently long explanation so the detection type accepts it.',
  }
  for k, v in pairs(over or {}) do s[k] = v end
  local r, errs = detection.new(s)
  assert(r, table.concat(errs or {}, '; '))
  return r
end

local CFG = { ['detectors.enabled'] = true }

H.suite('registry: construction and registration')

H.test('requires an injected detection_new function', function()
  H.eq(pcall(registry.new, {}, {}), false)
  H.eq(pcall(registry.new, { detection_new = 'nope' }, {}), false)
end)

H.test('registers a valid detector', function()
  local r = reg()
  local ok, err = r:register{ id = 'a.b', version = 1, kind = 'record', fn = function() end }
  H.eq(ok, true); H.is_nil(err)
  H.eq(r:ids()[1], 'a.b')
end)

H.test('rejects a duplicate id', function()
  local r = reg()
  r:register{ id = 'a.b', version = 1, kind = 'record', fn = function() end }
  local ok, err = r:register{ id = 'a.b', version = 2, kind = 'record', fn = function() end }
  H.eq(ok, false)
  H.ok(err:find('already registered', 1, true))
end)

H.test('rejects a bad spec', function()
  local r = reg()
  H.eq((r:register(nil)), false)
  H.eq((r:register{ version = 1, kind = 'record', fn = function() end }), false)
  H.eq((r:register{ id = 'x', kind = 'record', fn = function() end }), false)
  H.eq((r:register{ id = 'x', version = 1, kind = 'mystery', fn = function() end }), false)
  H.eq((r:register{ id = 'x', version = 1, kind = 'record' }), false)
end)

H.suite('registry: detection is off by default')

H.test('runs nothing when config disables detection', function()
  -- charter §4: build the observatory first. Phase 2 observes only.
  local r = reg()
  local ran = false
  r:register{ id = 'a.b', version = 1, kind = 'record',
              fn = function() ran = true; return nil end }
  r:run_record({}, {}, { ['detectors.enabled'] = false })
  H.eq(ran, false, 'a detector must not run while detection is disabled')
end)

H.test('respects a per-detector disable', function()
  local r = reg()
  local ran = false
  r:register{ id = 'a.b', version = 1, kind = 'record',
              fn = function() ran = true end, enabled = false }
  r:run_record({}, {}, CFG)
  H.eq(ran, false)
  r:set_enabled('a.b', true)
  r:run_record({}, {}, CFG)
  H.eq(ran, true)
end)

H.suite('registry: record detectors')

H.test('collects a returned result', function()
  local r = reg()
  r:register{ id = 'a.b', version = 1, kind = 'record',
              fn = function() return result_for('a.b', 1) end }
  local results, errors = r:run_record({}, {}, CFG)
  H.eq(#results, 1); H.eq(#errors, 0)
end)

H.test('nil is the normal case and not an error', function()
  local r = reg()
  r:register{ id = 'a.b', version = 1, kind = 'record', fn = function() return nil end }
  local results, errors = r:run_record({}, {}, CFG)
  H.eq(#results, 0); H.eq(#errors, 0)
  H.eq(r:stats()[1].errors_n, 0)
end)

H.test('a periodic detector does not run on a record', function()
  local r = reg()
  local ran = false
  r:register{ id = 'p.q', version = 1, kind = 'periodic', fn = function() ran = true end }
  r:run_record({}, {}, CFG)
  H.eq(ran, false)
end)

H.suite('registry: a throwing detector is contained')

H.test('a detector that errors does not propagate', function()
  local r = reg()
  r:register{ id = 'bad.one', version = 1, kind = 'record',
              fn = function() error('boom') end }
  local results, errors = r:run_record({}, {}, CFG)
  H.eq(#results, 0)
  H.eq(#errors, 1)
  H.ok(errors[1].err:find('boom', 1, true))
  H.eq(errors[1].detector_id, 'bad.one')
end)

H.test('a healthy detector still runs alongside a broken one', function()
  -- One bad detector must not cost the others' findings.
  local r = reg()
  r:register{ id = 'bad.one', version = 1, kind = 'record', fn = function() error('boom') end }
  r:register{ id = 'good.one', version = 1, kind = 'record',
              fn = function() return result_for('good.one', 1) end }
  local results, errors = r:run_record({}, {}, CFG)
  H.eq(#results, 1); H.eq(#errors, 1)
  H.eq(results[1].detector_id, 'good.one')
end)

H.suite('registry: circuit breaker')

H.test('trips after three consecutive failures', function()
  -- A broken detector must not degrade observability forever by being retried.
  local r = reg()
  r:register{ id = 'bad.one', version = 1, kind = 'record', fn = function() error('boom') end }
  for _ = 1, 3 do r:run_record({}, {}, CFG) end
  local st = r:stats()[1]
  H.eq(st.tripped, true)
  H.ok(st.trip_reason:find('3 consecutive failures', 1, true))
end)

H.test('a tripped detector stops being run', function()
  local r = reg()
  local calls = 0
  r:register{ id = 'bad.one', version = 1, kind = 'record',
              fn = function() calls = calls + 1; error('boom') end }
  for _ = 1, 10 do r:run_record({}, {}, CFG) end
  H.eq(calls, 3, 'it must stop calling the detector once tripped')
end)

H.test('a success resets the counter, so an intermittent fault does not trip', function()
  --[[
    Two failures then a success then two more failures must NOT trip. A transient nil
    from malformed telemetry is exactly what pcall already contains; auto-disabling on
    that would be too eager.
  ]]
  local r = reg()
  local n = 0
  r:register{ id = 'flaky', version = 1, kind = 'record', fn = function()
    n = n + 1
    if n == 3 then return nil end
    error('intermittent')
  end }
  for _ = 1, 5 do r:run_record({}, {}, CFG) end
  local st = r:stats()[1]
  H.eq(st.tripped, false, 'an intermittent fault must not accumulate towards a trip')
  H.eq(st.errors_n, 4)
end)

H.test('the threshold is configurable', function()
  local r = reg({ max_consecutive_failures = 1 })
  r:register{ id = 'bad.one', version = 1, kind = 'record', fn = function() error('x') end }
  r:run_record({}, {}, CFG)
  H.eq(r:stats()[1].tripped, true)
end)

H.test('a tripped breaker can be reset after a fix', function()
  local r = reg({ max_consecutive_failures = 1 })
  r:register{ id = 'bad.one', version = 1, kind = 'record', fn = function() error('x') end }
  r:run_record({}, {}, CFG)
  H.eq((r:reset('bad.one')), true)
  H.eq(r:stats()[1].tripped, false)
  H.eq((r:reset('nope')), false)
end)

H.suite('registry: audit-trail integrity')

H.test('a detector cannot emit a result attributed to another detector', function()
  --[[
    Otherwise one detector's bug could discredit another's findings, and an incident's
    detector list would be a lie.
  ]]
  local r = reg()
  r:register{ id = 'a.b', version = 1, kind = 'record',
              fn = function() return result_for('someone.else', 1) end }
  local results, errors = r:run_record({}, {}, CFG)
  H.eq(#results, 0)
  H.eq(#errors, 1)
  H.ok(errors[1].err:find('attributed to', 1, true))
end)

H.test('a detector cannot claim a version it is not registered as', function()
  -- An incident must record the version that actually ran.
  local r = reg()
  r:register{ id = 'a.b', version = 2, kind = 'record',
              fn = function() return result_for('a.b', 7) end }
  local results, errors = r:run_record({}, {}, CFG)
  H.eq(#results, 0)
  H.ok(errors[1].err:find('claiming v7', 1, true))
end)

H.test('a non-table return is rejected', function()
  local r = reg()
  r:register{ id = 'a.b', version = 1, kind = 'record', fn = function() return 'yes' end }
  local results, errors = r:run_record({}, {}, CFG)
  H.eq(#results, 0)
  H.ok(errors[1].err:find('not a DetectionResult', 1, true))
end)

H.suite('registry: periodic detectors')

H.test('collects a list of results', function()
  local r = reg()
  r:register{ id = 'p.q', version = 1, kind = 'periodic', fn = function()
    return { result_for('p.q', 1), result_for('p.q', 1) }
  end }
  local results, errors = r:run_periodic({}, CFG)
  H.eq(#results, 2); H.eq(#errors, 0)
end)

H.test('an empty list is fine', function()
  local r = reg()
  r:register{ id = 'p.q', version = 1, kind = 'periodic', fn = function() return {} end }
  local results, errors = r:run_periodic({}, CFG)
  H.eq(#results, 0); H.eq(#errors, 0)
end)

H.test('a non-list return is rejected', function()
  local r = reg()
  r:register{ id = 'p.q', version = 1, kind = 'periodic', fn = function() return 5 end }
  local _, errors = r:run_periodic({}, CFG)
  H.ok(errors[1].err:find('list of results', 1, true))
end)

H.test('a mislabelled result inside the list is rejected, good ones kept', function()
  local r = reg()
  r:register{ id = 'p.q', version = 1, kind = 'periodic', fn = function()
    return { result_for('p.q', 1), result_for('other.id', 1) }
  end }
  local results, errors = r:run_periodic({}, CFG)
  H.eq(#results, 1, 'the correctly attributed result should still be accepted')
  H.eq(#errors, 1)
end)

H.test('a record detector does not run on a periodic pass', function()
  local r = reg()
  local ran = false
  r:register{ id = 'a.b', version = 1, kind = 'record', fn = function() ran = true end }
  r:run_periodic({}, CFG)
  H.eq(ran, false)
end)

H.suite('registry: stats')

H.test('tracks runs, results and errors per detector', function()
  local r = reg()
  r:register{ id = 'a.b', version = 3, kind = 'record',
              fn = function() return result_for('a.b', 3) end }
  r:run_record({}, {}, CFG); r:run_record({}, {}, CFG)
  local st = r:stats()[1]
  H.eq(st.id, 'a.b'); H.eq(st.version, 3); H.eq(st.kind, 'record')
  H.eq(st.runs_n, 2); H.eq(st.results_n, 2); H.eq(st.errors_n, 0)
end)

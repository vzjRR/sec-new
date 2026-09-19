--[[
  tests/unit/test_entity_rate.lua

  Detector #3. The tests are weighted towards the three honesty constraints in the
  module header, because those are what stop it becoming a false-positive generator:
  unconfigured thresholds must not fire, unattributed creations must not be guessed at,
  and a lossy window must downgrade the result.
]]
local H = ...
local ER        = require('logic.entity_rate')
local detection = require('logic.detection')
local config_lib= require('lib.config')

local function cfg(over)
  local c = config_lib.defaults()
  c['detectors.enabled'] = true
  for k, v in pairs(over or {}) do c[k] = v end
  return c
end

local function det() return ER.detector({ detection_new = detection.new }) end

local function entity_record(over)
  local r = {
    schema_version = 1, ts = 1758204000000, mono = 1000, seq = 1,
    player_key = 'QB:ABCD1234', src = 7,
    category = 'entity', event = 'entity_created',
    source = 'event:entityCreated', trust = 'observed',
    measurements = { handle_n = 65540 },
    context = { entity_type = 2, model_hash = 1234, population_type = 6, bucket = 0 },
  }
  for k, v in pairs(over or {}) do
    if v == '__nil__' then r[k] = nil else r[k] = v end
  end
  return r
end

local function ctx_record(mono, over)
  local c = { entity_type = 2, bucket = 0 }
  for k, v in pairs((over or {}).context or {}) do c[k] = v end
  local r = entity_record({ mono = mono, context = c })
  for k, v in pairs(over or {}) do
    if k ~= 'context' then r[k] = v end
  end
  return r
end

--[[
  Combine a detection into an accumulator while ALWAYS evaluating the call.

  Deliberately not `fired = fired or d(...)`: `or` short-circuits, so once a detection
  had happened the detector would never be called again and every later event would be
  silently dropped. That bug hid two real failures in this file -- one of which turned
  out to be a genuine gap in the detector, not merely a test problem.
]]
local function pick(acc, result)
  if acc ~= nil then return acc end
  return result
end

H.suite('entity.rate: construction')

H.test('requires an injected detection_new', function()
  H.eq(pcall(ER.detector, {}), false)
end)

H.test('spec registers as a record detector', function()
  local s = ER.spec({ detection_new = detection.new })
  H.eq(s.id, 'entity.rate'); H.eq(s.kind, 'record'); H.eq(s.version, ER.VERSION)
end)

H.suite('entity.rate: thresholds default to NOT CONFIGURED')

H.test('fires nothing at all with default config, however many entities', function()
  --[[
    The most important test here. A creation rate is only abnormal relative to this
    server's own population, so shipping a number would ship a guess. The default
    must be silent.
  ]]
  local d, st, c = det(), ER.new_state(cfg()), cfg()
  for i = 1, 500 do
    H.is_nil(d(st, ctx_record(1000 + i * 10), c), 'fired at event ' .. i)
  end
end)

H.test('still counts while unconfigured, so a baseline can be derived', function()
  -- Observatory first: the detector must gather the data that sets its own threshold.
  local d, st, c = det(), ER.new_state(cfg()), cfg()
  for i = 1, 20 do d(st, ctx_record(1000 + i * 10), c) end
  H.ok(ER.stats(st).rate_window.keys_n > 0, 'counting must happen even when silent')
end)

H.suite('entity.rate: creation rate')

H.test('fires once a configured threshold is exceeded', function()
  local c = cfg{ ['detectors.entity_rate.max_per_window'] = 5 }
  local d, st = det(), ER.new_state(c)
  local fired
  for i = 1, 10 do
    local r = d(st, ctx_record(1000 + i * 10), c)
    if r then fired = fired or r end
  end
  H.ok(fired, 'expected a creation_rate detection')
  H.eq(fired.signal, 'creation_rate')
  H.eq(fired.detector_id, 'entity.rate')
  H.eq(fired.measurements.threshold_n, 5)
  H.ok(fired.measurements.created_n > 5)
end)

H.test('confidence stays at the modest level the spec sets', function()
  -- 0.5: rates are observed, but legitimate bursts exist (a garage, a convoy).
  local c = cfg{ ['detectors.entity_rate.max_per_window'] = 2 }
  local d, st = det(), ER.new_state(c)
  local fired
  for i = 1, 6 do fired = pick(fired, d(st, ctx_record(1000 + i * 10), c)) end
  H.near(fired.confidence, 0.5, 1e-9)
  H.eq(#fired.confidence_caps, 0, 'observed+derived must not trip the claimed cap')
end)

H.test('entity types are counted separately', function()
  -- 3 vehicles and 3 peds is not 6 of anything.
  local c = cfg{ ['detectors.entity_rate.max_per_window'] = 4 }
  local d, st = det(), ER.new_state(c)
  local fired
  for i = 1, 4 do
    fired = pick(fired, d(st, ctx_record(1000 + i * 10, { context = { entity_type = 2 } }), c))
    fired = pick(fired, d(st, ctx_record(1000 + i * 10, { context = { entity_type = 1 } }), c))
  end
  H.is_nil(fired, 'four of each type must not combine into eight')
end)

H.test('players are counted separately', function()
  local c = cfg{ ['detectors.entity_rate.max_per_window'] = 4 }
  local d, st = det(), ER.new_state(c)
  local fired
  for i = 1, 4 do
    fired = pick(fired, d(st, ctx_record(1000 + i * 10, { player_key = 'QB:AAA' }), c))
    fired = pick(fired, d(st, ctx_record(1000 + i * 10, { player_key = 'QB:BBB' }), c))
  end
  H.is_nil(fired)
end)

H.test('a sustained burst produces one finding, not hundreds', function()
  local c = cfg{ ['detectors.entity_rate.max_per_window'] = 3,
                 ['detectors.entity_rate.redetect_ms'] = 30000 }
  local d, st = det(), ER.new_state(c)
  local n = 0
  for i = 1, 200 do
    if d(st, ctx_record(1000 + i * 10), c) then n = n + 1 end
  end
  H.eq(n, 1, 'the de-duplication window must collapse a burst into one detection')
end)

H.test('it can fire again after the redetect window', function()
  local c = cfg{ ['detectors.entity_rate.max_per_window'] = 3,
                 ['detectors.entity_rate.redetect_ms'] = 5000 }
  local d, st = det(), ER.new_state(c)
  local n = 0
  for i = 1, 20 do if d(st, ctx_record(1000 + i * 100), c) then n = n + 1 end end
  for i = 1, 20 do if d(st, ctx_record(20000 + i * 100), c) then n = n + 1 end end
  H.ok(n >= 2, 'a later burst should be reportable again, got ' .. n)
end)

H.suite('entity.rate: legitimate causes must not fire')

H.test('an entity owned by a resource script is not the player\'s', function()
  --[[
    Every legitimate spawner on a QBCore server (qb-garages, qb-vehicleshop, job
    scripts, admin menus) sets an entity script. Counting those against the player
    would make normal play look like abuse -- the single most likely false positive.
  ]]
  local c = cfg{ ['detectors.entity_rate.max_per_window'] = 2 }
  local d, st = det(), ER.new_state(c)
  for i = 1, 50 do
    H.is_nil(d(st, ctx_record(1000 + i * 10,
      { context = { script = 'qb-garages' } }), c), 'fired at ' .. i)
  end
end)

H.test('a SYSTEM-keyed creation is never attributed to a player', function()
  local c = cfg{ ['detectors.entity_rate.max_per_window'] = 2 }
  local d, st = det(), ER.new_state(c)
  for i = 1, 50 do
    H.is_nil(d(st, ctx_record(1000 + i * 10, { player_key = 'SYSTEM' }), c))
  end
end)

H.test('unattributed creations are COUNTED, not guessed at', function()
  --[[
    entityCreating carries only a handle and NetworkGetEntityOwner is client-side, so
    many creations genuinely cannot be tied to a player. Attributing them to the
    nearest one would be inventing evidence about a specific person.
  ]]
  local c = cfg{ ['detectors.entity_rate.max_per_window'] = 2 }
  local d, st = det(), ER.new_state(c)
  for i = 1, 10 do d(st, ctx_record(1000 + i * 10, { player_key = 'SYSTEM' }), c) end
  H.eq(ER.stats(st).unattributed_n, 10, 'the loss of attribution must be visible')
end)

H.test('ignores non-entity records entirely', function()
  local c = cfg{ ['detectors.entity_rate.max_per_window'] = 1 }
  local d, st = det(), ER.new_state(c)
  for i = 1, 20 do
    H.is_nil(d(st, ctx_record(1000 + i, { category = 'combat' }), c))
    H.is_nil(d(st, ctx_record(1000 + i, { category = 'movement' }), c))
  end
end)

H.test('ignores a record with no monotonic time', function()
  local c = cfg{ ['detectors.entity_rate.max_per_window'] = 1 }
  local d, st = det(), ER.new_state(c)
  H.is_nil(d(st, entity_record{ mono = '__nil__' }, c))
end)

H.test('tolerates a missing state or record', function()
  local c = cfg()
  H.is_nil(det()(nil, entity_record(), c))
  H.is_nil(det()(ER.new_state(c), nil, c))
end)

H.suite('entity.rate: churn')

H.test('create-then-quickly-remove counts as churn and fires', function()
  local c = cfg{ ['detectors.entity_rate.min_churn_n'] = 3,
                 ['detectors.entity_rate.churn_lifetime_ms'] = 2000 }
  local d, st = det(), ER.new_state(c)
  local fired
  -- Strictly increasing times: create at t0, remove at t0+100, next create at t0+200.
  for i = 1, 6 do
    local h = 1000 + i
    local t0 = 1000 + (i - 1) * 200
    d(st, ctx_record(t0, { measurements = { handle_n = h } }), c)
    fired = pick(fired, d(st, entity_record{
      mono = t0 + 100, event = 'entity_removed', measurements = { handle_n = h } }, c))
  end
  H.ok(fired, 'expected an entity_churn detection')
  H.eq(fired.signal, 'entity_churn')
  H.near(fired.confidence, 0.6, 1e-9)
  H.eq(fired.severity, 'medium')
end)

H.test('a long-lived entity is not churn', function()
  local c = cfg{ ['detectors.entity_rate.min_churn_n'] = 2,
                 ['detectors.entity_rate.churn_lifetime_ms'] = 2000 }
  local d, st = det(), ER.new_state(c)
  for i = 1, 10 do
    local h = 2000 + i
    local t0 = 1000 + (i - 1) * 40000
    d(st, ctx_record(t0, { measurements = { handle_n = h } }), c)
    H.is_nil(d(st, entity_record{
      mono = t0 + 30000, event = 'entity_removed',
      measurements = { handle_n = h } }, c), 'a 30s lifetime is not churn')
  end
end)

H.test('a removal with no matching creation is ignored', function()
  local c = cfg{ ['detectors.entity_rate.min_churn_n'] = 1 }
  local d, st = det(), ER.new_state(c)
  H.is_nil(d(st, entity_record{ event = 'entity_removed',
                                measurements = { handle_n = 999999 } }, c))
end)

H.suite('entity.rate: a lossy window downgrades the finding')

H.test('eviction caps confidence and says so in the explanation', function()
  --[[
    A count taken after the window evicted events is a FLOOR, not a measurement.
    Reporting it at full confidence would state a number the detector cannot stand
    behind.
  ]]
  local c = cfg{ ['detectors.entity_rate.max_per_window'] = 3,
                 ['detectors.entity_rate.max_events_per_key'] = 8 }
  local d, st = det(), ER.new_state(c)
  local fired
  for i = 1, 60 do fired = pick(fired, d(st, ctx_record(1000 + i * 10), c)) end
  -- Force saturation then allow a re-detection.
  local c2 = cfg{ ['detectors.entity_rate.max_per_window'] = 3,
                  ['detectors.entity_rate.max_events_per_key'] = 8,
                  ['detectors.entity_rate.redetect_ms'] = 1 }
  local later
  for i = 1, 60 do later = pick(later, d(st, ctx_record(5000 + i * 10), c2)) end
  H.ok(later, 'expected a later detection once saturated')
  H.ok(st.rate_window:lossy(), 'the window should be lossy by now')
  H.ok(later.confidence <= 0.3, 'confidence must be reduced, got ' .. later.confidence)
  H.ok(later.explanation:find('FLOOR', 1, true), 'the explanation must say so')
  H.eq(later.context.window_lossy, true)
end)

H.suite('entity.rate: explanation quality')

H.test('the explanation names the count, the threshold and the window', function()
  local c = cfg{ ['detectors.entity_rate.max_per_window'] = 3 }
  local d, st = det(), ER.new_state(c)
  local fired
  for i = 1, 10 do fired = pick(fired, d(st, ctx_record(1000 + i * 10), c)) end
  H.ok(#fired.explanation > 80)
  H.ok(fired.explanation:find('threshold', 1, true))
  H.ok(fired.explanation:find("server's own", 1, true),
    'it must say the threshold is local, not universal')
end)

H.test('evidence refs carry the correlation id when present', function()
  local c = cfg{ ['detectors.entity_rate.max_per_window'] = 2 }
  local d, st = det(), ER.new_state(c)
  local fired
  for i = 1, 6 do
    fired = pick(fired, d(st, ctx_record(1000 + i * 10, { correlation_id = 'c_ent' }), c))
  end
  H.eq(fired.evidence_refs[1], 'c_ent')
end)

H.suite('entity.rate: housekeeping')

H.test('forget clears a player without disturbing others', function()
  local c = cfg{ ['detectors.entity_rate.max_per_window'] = 3 }
  local d, st = det(), ER.new_state(c)
  for i = 1, 3 do
    d(st, ctx_record(1000 + i * 10, { player_key = 'QB:AAA' }), c)
    d(st, ctx_record(1000 + i * 10, { player_key = 'QB:BBB' }), c)
  end
  ER.forget(st, 'QB:AAA')
  H.eq(st.rate_window:count('QB:AAA|vehicle', 2000), 0)
  H.ok(st.rate_window:count('QB:BBB|vehicle', 2000) > 0)
end)

H.test('prune drops idle keys', function()
  local c = cfg()
  local d, st = det(), ER.new_state(c)
  d(st, ctx_record(1000), c)
  H.ok(ER.prune(st, 10 ^ 6) >= 1)
end)

H.test('stats expose window bounds and attribution loss', function()
  local st = ER.new_state(cfg())
  local s = ER.stats(st)
  H.ok(s.rate_window.max_keys > 0)
  H.eq(s.unattributed_n, 0)
  H.is_nil(ER.stats(nil))
end)

H.test('tracked live entities are bounded', function()
  local c = cfg{ ['detectors.entity_rate.max_tracked_entities'] = 10 }
  local d, st = det(), ER.new_state(c)
  for i = 1, 500 do
    d(st, ctx_record(1000 + i, { measurements = { handle_n = 10000 + i } }), c)
  end
  H.ok(st.live_n <= 10, 'live entity tracking must stay bounded, got ' .. st.live_n)
end)

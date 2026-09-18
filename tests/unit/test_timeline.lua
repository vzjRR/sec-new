--[[
  tests/unit/test_timeline.lua

  The timeline's most important job is SURFACING GAPS. An investigator reading a
  timeline with a silent hole would infer continuity that never existed -- concluding
  "nothing happened between these events" when the record of what happened was
  discarded. These tests treat that as the primary requirement.
]]
local H = ...
local timeline = require('logic.timeline')

local function rec(seq, mono, over)
  local r = {
    schema_version = 1, seq = seq, mono = mono, ts = 1758204000000 + mono,
    player_key = 'QB:ABCD1234', category = 'combat', event = 'weapon_damage',
    source = 'event:weaponDamageEvent', trust = 'claimed',
    measurements = {}, context = {},
  }
  for k, v in pairs(over or {}) do r[k] = v end
  return r
end

H.suite('timeline: ordering')

H.test('orders by monotonic time', function()
  local t = timeline.build({ rec(3, 300), rec(1, 100), rec(2, 200) })
  H.eq(t.entries[1].record.seq, 1)
  H.eq(t.entries[2].record.seq, 2)
  H.eq(t.entries[3].record.seq, 3)
end)

H.test('breaks ties on seq when mono collides', function()
  local t = timeline.build({ rec(2, 100), rec(1, 100) })
  H.eq(t.entries[1].record.seq, 1)
  H.eq(t.entries[2].record.seq, 2)
end)

H.test('orders by mono, never by wall clock', function()
  -- A wall clock can step backwards; ordering by it would reorder the timeline and
  -- could invert cause and effect.
  local a = rec(1, 100, { ts = 9999 })   -- wall clock far in the future
  local b = rec(2, 200, { ts = 1 })      -- wall clock stepped back
  local t = timeline.build({ b, a })
  H.eq(t.entries[1].record.seq, 1, 'mono must win over ts')
  H.eq(t.entries[2].record.seq, 2)
end)

H.test('does not mutate the caller list', function()
  local input = { rec(3, 300), rec(1, 100) }
  timeline.build(input)
  H.eq(input[1].seq, 3, 'the caller list must be left alone')
end)

H.test('handles an empty input', function()
  local t = timeline.build({})
  H.eq(#t.entries, 0)
  H.eq(t.stats.records_n, 0)
  H.is_nil(t.stats.span_ms)
end)

H.suite('timeline: GAPS are surfaced, never silent')

H.test('detects a missing record from a seq discontinuity', function()
  local t = timeline.build({ rec(1, 100), rec(3, 300) })
  H.eq(t.stats.gaps_n, 1)
  H.eq(t.stats.missing_n, 1)
  local gap = t.entries[2]
  H.eq(gap.kind, 'gap')
  H.eq(gap.after_seq, 1); H.eq(gap.before_seq, 3)
  H.eq(gap.missing_n, 1)
end)

H.test('a gap is a first-class ENTRY, in position', function()
  -- Not a footnote in stats: it appears between the records it separates, so it
  -- cannot be skimmed past.
  local t = timeline.build({ rec(1, 100), rec(5, 500), rec(6, 600) })
  H.eq(#t.entries, 4)
  H.eq(t.entries[1].kind, 'record')
  H.eq(t.entries[2].kind, 'gap')
  H.eq(t.entries[3].kind, 'record')
  H.eq(t.entries[4].kind, 'record')
end)

H.test('the gap note warns against reading continuity across it', function()
  -- seq 1 then seq 4 means records 2 and 3 are missing: two, not three.
  local t = timeline.build({ rec(1, 100), rec(4, 400) })
  local gap = t.entries[2]
  H.eq(gap.missing_n, 2)
  H.ok(gap.note:find('do not read continuity', 1, true))
  H.eq(gap.duration_ms, 300, 'the gap must report the wall of time it spans')
end)

H.test('counts multiple gaps', function()
  local t = timeline.build({ rec(1, 100), rec(3, 300), rec(7, 700) })
  H.eq(t.stats.gaps_n, 2)
  H.eq(t.stats.missing_n, 1 + 3)
end)

H.test('contiguous records produce no gaps', function()
  local t = timeline.build({ rec(1, 100), rec(2, 200), rec(3, 300) })
  H.eq(t.stats.gaps_n, 0)
  H.eq(t.stats.missing_n, 0)
end)

H.test('a filtered timeline does NOT report false gaps', function()
  --[[
    Filtering legitimately leaves non-contiguous seq values. Reporting those as lost
    evidence would be a false alarm about our own data -- and would train an
    investigator to ignore real gap warnings.
  ]]
  local recs = {
    rec(1, 100, { correlation_id = 'c_a' }),
    rec(2, 200, { correlation_id = 'c_b' }),
    rec(3, 300, { correlation_id = 'c_a' }),
  }
  local t = timeline.build(recs, { correlation_id = 'c_a' })
  H.eq(t.stats.records_n, 2)
  H.eq(t.stats.gaps_n, 0, 'seq 1 then 3 is expected after filtering')
  H.eq(t.stats.filtered, true)
end)

H.suite('timeline: filtering')

H.test('filters by correlation_id', function()
  local t = timeline.build({
    rec(1, 100, { correlation_id = 'c_a' }),
    rec(2, 200, { correlation_id = 'c_b' }),
  }, { correlation_id = 'c_a' })
  H.eq(t.stats.records_n, 1)
end)

H.test('filters by player_key', function()
  local t = timeline.build({
    rec(1, 100, { player_key = 'QB:AAA' }),
    rec(2, 200, { player_key = 'QB:BBB' }),
  }, { player_key = 'QB:BBB' })
  H.eq(t.stats.records_n, 1)
  H.eq(t.entries[1].record.player_key, 'QB:BBB')
end)

H.suite('timeline: completeness')

H.test('a contiguous timeline is complete', function()
  local ok, reason = timeline.is_complete(
    timeline.build({ rec(1, 100), rec(2, 200) }))
  H.eq(ok, true); H.is_nil(reason)
end)

H.test('a gapped timeline is incomplete, and says so in the right words', function()
  -- "insufficient evidence" not "absence of evidence" -- the distinction is the whole
  -- reason gaps are tracked.
  local ok, reason = timeline.is_complete(timeline.build({ rec(1, 100), rec(5, 500) }))
  H.eq(ok, false)
  H.ok(reason:find('insufficient evidence', 1, true))
  H.ok(reason:find('not absence of evidence', 1, true))
end)

H.test('buffer drops make a timeline incomplete even with contiguous seq', function()
  -- The buffer may have dropped records that never reached this set at all.
  local t = timeline.build({ rec(1, 100), rec(2, 200) }, { dropped_n = 7 })
  local ok, reason = timeline.is_complete(t)
  H.eq(ok, false)
  H.ok(reason:find('discarded 7', 1, true))
end)

H.test('is_complete tolerates nil', function()
  H.eq((timeline.is_complete(nil)), true)
end)

H.suite('timeline: trust summary')

H.test('reports how much of the story the attacker controlled', function()
  local t = timeline.build({
    rec(1, 100, { trust = 'claimed' }),
    rec(2, 200, { trust = 'claimed' }),
    rec(3, 300, { trust = 'observed', category = 'movement' }),
    rec(4, 400, { trust = 'observed', category = 'movement' }),
  })
  local s = timeline.trust_summary(t)
  H.eq(s.claimed_n, 2); H.eq(s.observed_n, 2)
  H.near(s.claimed_pct, 50.0, 1e-9)
end)

H.test('warns when a timeline is entirely client-claimed', function()
  local t = timeline.build({ rec(1, 100, { trust = 'claimed' }) })
  local s = timeline.trust_summary(t)
  H.ok(s.note:find('entirely client-claimed', 1, true))
  H.ok(s.note:find('cannot support a high-confidence conclusion', 1, true))
end)

H.test('notes when a timeline is entirely server-observed', function()
  local t = timeline.build({ rec(1, 100, { trust = 'observed' }) })
  H.ok(timeline.trust_summary(t).note:find('entirely server-observed', 1, true))
end)

H.test('handles a timeline with no trust-labelled records', function()
  local t = timeline.build({ rec(1, 100, { trust = 'derived' }) })
  local s = timeline.trust_summary(t)
  H.eq(s.claimed_n, 0); H.eq(s.observed_n, 0)
  H.is_nil(s.claimed_pct)
end)

H.suite('timeline: stats')

H.test('reports span, category and trust breakdowns', function()
  local t = timeline.build({
    rec(1, 100, { category = 'combat', trust = 'claimed' }),
    rec(2, 600, { category = 'movement', trust = 'observed' }),
  })
  H.eq(t.stats.span_ms, 500)
  H.eq(t.stats.first_mono, 100)
  H.eq(t.stats.last_mono, 600)
  H.eq(t.stats.categories.combat, 1)
  H.eq(t.stats.categories.movement, 1)
  H.eq(t.stats.trust.claimed, 1)
  H.eq(t.stats.trust.observed, 1)
end)

H.test('reports the buffer drop count alongside seq gaps', function()
  -- They measure different things and may disagree; that discrepancy is information.
  local t = timeline.build({ rec(1, 100), rec(3, 300) }, { dropped_n = 12 })
  H.eq(t.stats.missing_n, 1)
  H.eq(t.stats.buffer_dropped_n, 12)
end)

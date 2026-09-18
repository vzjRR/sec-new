--[[
  tests/unit/test_clock.lua

  The clock exists to stop a wall-clock step or a non-monotonic source from
  manufacturing impossible intervals (docs/TELEMETRY_SCHEMA.md §1). Those would look
  exactly like the anomalies we detect, so this module's failure mode is a FALSE
  ACCUSATION. It is tested accordingly.
]]
local H = ...
local clock = require('logic.clock')

local function fake(wall_seq, mono_seq)
  local wi, mi = 0, 0
  return clock.new(
    function() wi = wi + 1; return wall_seq[math.min(wi, #wall_seq)] end,
    function() mi = mi + 1; return mono_seq[math.min(mi, #mono_seq)] end
  )
end

H.suite('clock: construction')

H.test('requires both time functions', function()
  H.eq(pcall(clock.new, nil, function() return 0 end), false)
  H.eq(pcall(clock.new, function() return 0 end, nil), false)
end)

H.suite('clock: monotonic guarantee')

H.test('passes a well-behaved monotonic source through', function()
  local c = fake({ 1 }, { 100, 200, 300 })
  H.eq(c:mono(), 100); H.eq(c:mono(), 200); H.eq(c:mono(), 300)
  H.eq(c:regressions(), 0)
end)

H.test('clamps a regressing source instead of returning time travel', function()
  local c = fake({ 1 }, { 500, 400, 600 })
  H.eq(c:mono(), 500)
  H.eq(c:mono(), 500, 'a backwards reading must be clamped, not passed through')
  H.eq(c:mono(), 600)
end)

H.test('counts regressions so they surface as a health signal', function()
  local c = fake({ 1 }, { 500, 400, 300, 700 })
  c:mono(); c:mono(); c:mono(); c:mono()
  H.eq(c:regressions(), 2)
end)

H.suite('clock: wall time is independent')

H.test('wall time is read from its own source and may jump', function()
  -- A wall clock going backwards is allowed: it is display-only, and clamping it
  -- would hide an operator/NTP event that an investigator should see.
  local c = fake({ 1000, 900 }, { 1 })
  H.eq(c:wall(), 1000)
  H.eq(c:wall(), 900)
end)

H.suite('clock: interval_ms refuses to guess')

H.test('computes a normal forward interval', function()
  local c = fake({ 1 }, { 1 })
  H.eq(c:interval_ms(100, 250), 150)
end)

H.test('returns nil -- not zero -- for a backwards interval', function()
  local c = fake({ 1 }, { 1 })
  -- Returning 0 would let a detector read a missing interval as an instantaneous
  -- one, which is how a clock glitch becomes an "impossible reaction time".
  H.is_nil(c:interval_ms(250, 100))
end)

H.test('returns nil for non-numeric input', function()
  local c = fake({ 1 }, { 1 })
  H.is_nil(c:interval_ms(nil, 100))
  H.is_nil(c:interval_ms(100, nil))
  H.is_nil(c:interval_ms('100', 200))
end)

H.test('a zero interval is a real measurement and is preserved', function()
  local c = fake({ 1 }, { 1 })
  H.eq(c:interval_ms(100, 100), 0)
end)

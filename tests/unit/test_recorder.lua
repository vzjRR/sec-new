--[[
  tests/unit/test_recorder.lua

  An experiment harness is a measuring instrument, and a bad instrument is worse than
  none: it produces numbers that look authoritative and are wrong. These tests pin the
  guards that stop that.
]]
local H = ...
local R = require('logic.recorder')

local function rec() return R.new({ mode = 'LAB', build = '35945' }) end

H.suite('recorder: a conclusion must be readable against the evidence standard')

H.test('accepts a properly tagged conclusion', function()
  local r = rec()
  local ok, err = r:record{
    id = 'EXP-009', question = 'Is require available?', status = R.CONCLUDED,
    tag = 'FACT', finding = 'require is not available to resource scripts',
  }
  H.eq(ok, true, tostring(err))
end)

H.test('refuses a conclusion with no FACT/OBSERVATION/HYPOTHESIS tag', function()
  -- Untagged, a reader must guess whether it is fact or speculation.
  local ok, err = rec():record{ id = 'EXP-009', status = R.CONCLUDED,
                                finding = 'something was concluded here' }
  H.eq(ok, false)
  H.ok(err:find('tag', 1, true))
end)

H.test('refuses an unknown tag', function()
  local ok = rec():record{ id = 'E', status = R.CONCLUDED, tag = 'TRUTH',
                           finding = 'a finding of some length' }
  H.eq(ok, false)
end)

H.test('refuses a conclusion with no stated finding', function()
  local ok, err = rec():record{ id = 'E', status = R.CONCLUDED, tag = 'FACT' }
  H.eq(ok, false)
  H.ok(err:find('finding', 1, true))
end)

H.suite('recorder: inconclusive is a first-class outcome')

H.test('an experiment that could not run must give a reason', function()
  --[[
    "It didn't work" is not a result; why it didn't is. Without the reason, an
    experiment that could not run would read exactly like one that found nothing.
  ]]
  local ok, err = rec():record{ id = 'EXP-001', status = R.INCONCLUSIVE }
  H.eq(ok, false)
  H.ok(err:find('no reason', 1, true))
end)

H.test('accepts inconclusive with a reason', function()
  H.eq((rec():record{ id = 'EXP-001', status = R.INCONCLUSIVE,
                      reason = 'no player was connected during the run' }), true)
end)

H.test('failed and skipped also require a reason', function()
  H.eq((rec():record{ id = 'E', status = R.FAILED }), false)
  H.eq((rec():record{ id = 'E', status = R.SKIPPED }), false)
  H.eq((rec():record{ id = 'E', status = R.SKIPPED,
                      reason = 'requires a second resource' }), true)
end)

H.test('rejects an unknown status', function()
  H.eq((rec():record{ id = 'E', status = 'probably-fine', reason = 'x' }), false)
end)

H.test('rejects a missing id or a non-table', function()
  H.eq((rec():record{ status = R.SKIPPED, reason = 'xxxxx' }), false)
  H.eq((rec():record('nope')), false)
end)

H.suite('recorder: accumulation')

H.test('records are retrievable and id-ordered', function()
  local r = rec()
  r:record{ id = 'EXP-009', status = R.SKIPPED, reason = 'not run yet' }
  r:record{ id = 'EXP-001', status = R.SKIPPED, reason = 'not run yet' }
  local all = r:all()
  H.eq(#all, 2)
  H.eq(all[1].id, 'EXP-001')
  H.eq(r:get('EXP-009').status, R.SKIPPED)
end)

H.test('re-recording the same id replaces rather than duplicates', function()
  local r = rec()
  r:record{ id = 'EXP-001', status = R.SKIPPED, reason = 'no player yet' }
  r:record{ id = 'EXP-001', status = R.CONCLUDED, tag = 'OBSERVATION',
            finding = 'camera rotation updates about every 250ms' }
  H.eq(#r:all(), 1)
  H.eq(r:get('EXP-001').status, R.CONCLUDED)
end)

H.suite('recorder: summary reports what is still blocked')

H.test('separates unblocked from still-blocked experiments', function()
  local r = rec()
  r:record{ id = 'EXP-001', status = R.CONCLUDED, tag = 'OBSERVATION',
            finding = 'camera rotation characterised', blocks = 'aim detection' }
  r:record{ id = 'EXP-002', status = R.INCONCLUSIVE,
            reason = 'no shots were fired during the capture window',
            blocks = 'combat sequence statistics' }
  local s = r:summary()
  H.eq(s.total, 2); H.eq(s.concluded, 1); H.eq(s.inconclusive, 1)
  H.eq(s.unblocked[1], 'EXP-001')
  H.eq(s.still_blocked[1], 'EXP-002')
end)

H.suite('recorder: rendering')

H.test('renders findings, reasons and the blocked list', function()
  local r = rec()
  r:record{ id = 'EXP-009', question = 'Is require available?', status = R.CONCLUDED,
            tag = 'FACT', finding = 'require is nil in resource scripts',
            samples_n = 1, detail = { require_type = 'nil' } }
  r:record{ id = 'EXP-001', status = R.INCONCLUSIVE,
            reason = 'no player connected', blocks = 'aim detection' }
  local text = r:render()
  H.ok(text:find('EXP-009', 1, true))
  H.ok(text:find('FACT', 1, true))
  H.ok(text:find('require is nil', 1, true))
  H.ok(text:find('no player connected', 1, true))
  H.ok(text:find('STILL BLOCKED', 1, true))
  H.ok(text:find('require_type', 1, true))
end)

H.test('rendering an empty recorder does not crash', function()
  H.ok(#rec():render() > 0)
end)

H.test('bundle is serialisable and carries meta plus summary', function()
  local r = rec()
  r:record{ id = 'E-1', status = R.SKIPPED, reason = 'placeholder' }
  local b = r:bundle()
  H.eq(b.meta.mode, 'LAB')
  H.eq(#b.results, 1)
  H.eq(b.summary.total, 1)
end)

H.suite('recorder: stats refuse to over-claim')

H.test('returns nil below the minimum sample count', function()
  --[[
    A mean computed from one value looks like a measurement and is noise. Refusing is
    the honest answer, and it forces the caller to decide what "enough" means.
  ]]
  local s, why = R.stats({ 10 }, 5)
  H.is_nil(s)
  H.ok(why:find('need at least 5', 1, true))
  H.is_nil((R.stats(nil, 5)))
  H.is_nil((R.stats({}, 5)))
end)

H.test('computes the expected summary for a known set', function()
  local s = R.stats({ 1, 2, 3, 4, 5 }, 5)
  H.eq(s.n, 5); H.eq(s.min, 1); H.eq(s.max, 5)
  H.near(s.mean, 3.0, 1e-9)
  H.near(s.stddev, math.sqrt(2.5), 1e-9)
  H.eq(s.p50, 3)
end)

H.test('is order-independent', function()
  local a = R.stats({ 5, 1, 4, 2, 3 }, 5)
  local b = R.stats({ 1, 2, 3, 4, 5 }, 5)
  H.eq(a.mean, b.mean); H.eq(a.p50, b.p50); H.eq(a.min, b.min)
end)

H.test('percentiles land inside the data', function()
  local vals = {}
  for i = 1, 100 do vals[i] = i end
  local s = R.stats(vals, 5)
  H.eq(s.p50, 50); H.eq(s.p90, 90); H.eq(s.p99, 99)
end)

H.test('a constant series has zero spread', function()
  local vals = {}
  for i = 1, 10 do vals[i] = 7 end
  local s = R.stats(vals, 5)
  H.near(s.stddev, 0.0, 1e-12)
  H.eq(s.min, s.max)
end)

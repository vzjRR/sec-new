--[[
  tests/unit/test_envelope.lua
  Envelope construction must be the single place records are shaped
  (docs/ARCHITECTURE.md §4.2), so these tests pin the invariants every adapter relies on.
]]
local H = ...
local clock    = require('logic.clock')
local envelope = require('logic.envelope')
local schema   = require('logic.schema')

local function builder(mode)
  local t = 0
  local c = clock.new(
    function() return 1758204000000 end,
    function() t = t + 10; return t end
  )
  return envelope.new(c, { mode = mode or 'LAB' })
end

local function spec(over)
  local s = {
    player_key = 'QB:ABCD1234',
    src = 7,
    category = 'movement',
    event = 'movement_sample',
    source = 'poll:entity_state',
    trust = 'observed',
    measurements = { speed_mps = 4.5 },
  }
  for k, v in pairs(over or {}) do s[k] = v end
  return s
end

H.suite('envelope: basics')

H.test('requires a clock', function()
  H.eq(pcall(envelope.new, nil, {}), false)
end)

H.test('builds a schema-valid record', function()
  local r = builder():build(spec())
  local ok, errs = schema.validate(r)
  H.ok(ok, table.concat(errs, '; '))
end)

H.test('stamps the current schema version', function()
  H.eq(builder():build(spec()).schema_version, schema.SCHEMA_VERSION)
end)

H.suite('envelope: sequence numbers')

H.test('sequence is monotonic and starts at 1', function()
  local b = builder()
  H.eq(b:build(spec()).seq, 1)
  H.eq(b:build(spec()).seq, 2)
  H.eq(b:build(spec()).seq, 3)
end)

H.test('sequence gives a total order when timestamps collide', function()
  -- Two records can share a millisecond; replay and fixture comparison need a
  -- deterministic order regardless (docs/TELEMETRY_SCHEMA.md §1).
  local c = clock.new(function() return 5 end, function() return 5 end)
  local b = envelope.new(c, {})
  local a, z = b:build(spec()), b:build(spec())
  H.eq(a.ts, z.ts)
  H.eq(a.mono, z.mono)
  H.ok(z.seq > a.seq, 'seq must break the tie')
end)

H.suite('envelope: mode stamping')

H.test('stamps the resolved mode onto every record', function()
  H.eq(builder('LAB'):build(spec()).context.mode, 'LAB')
  H.eq(builder('PRODUCTION'):build(spec()).context.mode, 'PRODUCTION')
end)

H.test('defaults to PRODUCTION when no mode is given', function()
  -- Failing closed matters: an unstamped record must not be mistaken for lab data.
  local c = clock.new(function() return 1 end, function() return 1 end)
  H.eq(envelope.new(c, {}):build(spec()).context.mode, 'PRODUCTION')
end)

H.test('an explicit context mode wins over the builder default', function()
  H.eq(builder('LAB'):build(spec{ context = { mode = 'PRODUCTION' } }).context.mode,
       'PRODUCTION')
end)

H.suite('envelope: caller isolation')

H.test('does not mutate the caller context table', function()
  local ctx = { weapon_hash = 1 }
  builder():build(spec{ context = ctx })
  H.is_nil(ctx.mode, 'builder must copy, not annotate the caller table')
end)

H.test('missing measurements and context become empty tables', function()
  local r = builder():build(spec{ measurements = nil, context = nil })
  H.eq(type(r.measurements), 'table')
  H.eq(type(r.context), 'table')
end)

H.test('rejects a non-table spec', function()
  H.eq(pcall(function() return builder():build('nope') end), false)
end)

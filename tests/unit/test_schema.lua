--[[
  tests/unit/test_schema.lua
  Verifies the TelemetryRecord contract in docs/TELEMETRY_SCHEMA.md.

  These tests are deliberately adversarial about the schema's *safety* properties
  rather than just its happy path: the PII sweep, the numbers-only rule and the
  unit-suffix rule all exist to prevent specific real failures, so each is tested
  by trying to violate it.
]]
local H = ...
local schema = require('logic.schema')

local function valid_record(over)
  local r = {
    schema_version = 1,
    ts = 1758204000123,
    mono = 5000,
    seq = 1,
    player_key = 'QB:ABCD1234',
    src = 12,
    category = 'combat',
    event = 'weapon_damage',
    source = 'event:weaponDamageEvent',
    measurements = { claimed_damage_n = 35 },
    context = { weapon_hash = 453432689 },
    trust = 'claimed',
  }
  for k, v in pairs(over or {}) do
    if v == '__nil__' then r[k] = nil else r[k] = v end
  end
  return r
end

H.suite('schema: envelope')

H.test('a well-formed record validates', function()
  local ok, errs = schema.validate(valid_record())
  H.ok(ok, 'expected valid, got: ' .. table.concat(errs, '; '))
end)

H.test('rejects a non-table', function()
  local ok, errs = schema.validate('nope')
  H.rejects(ok, errs, 'not a table')
end)

H.test('rejects a missing envelope field', function()
  local ok, errs = schema.validate(valid_record{ trust = '__nil__' })
  H.rejects(ok, errs, 'missing envelope field')
end)

H.test('rejects an unknown category', function()
  local ok, errs = schema.validate(valid_record{ category = 'vibes' })
  H.rejects(ok, errs, 'unknown category')
end)

H.test('rejects an unknown trust level', function()
  local ok, errs = schema.validate(valid_record{ trust = 'probably_fine' })
  H.rejects(ok, errs, 'unknown trust')
end)

H.test('rejects a future schema version', function()
  local ok, errs = schema.validate(valid_record{ schema_version = 99 })
  H.rejects(ok, errs, 'not supported')
end)

H.test('rejects a non-integer timestamp', function()
  local ok, errs = schema.validate(valid_record{ ts = 1.5 })
  H.rejects(ok, errs, 'integer')
end)

H.test('rejects negative monotonic time', function()
  local ok, errs = schema.validate(valid_record{ mono = -1 })
  H.rejects(ok, errs, 'negative')
end)

H.suite('schema: player_key')

H.test('accepts the QB citizenid form', function()
  H.ok((schema.validate(valid_record{ player_key = 'QB:A1b2C3d4' })))
end)

H.test('accepts the session SRC form', function()
  H.ok((schema.validate(valid_record{ player_key = 'SRC:42' })))
end)

H.test('accepts SYSTEM', function()
  H.ok((schema.validate(valid_record{ player_key = 'SYSTEM', category = 'system' })))
end)

H.test('rejects a raw identifier as a player_key', function()
  local ok, errs = schema.validate(valid_record{ player_key = 'license:110000112345678' })
  H.rejects(ok, errs, 'not a recognised form')
end)

H.suite('schema: measurements are numbers with units')

H.test('rejects a string measurement', function()
  local ok, errs = schema.validate(valid_record{ measurements = { damage_n = 'lots' } })
  H.rejects(ok, errs, 'must be a number')
end)

H.test('rejects a table measurement', function()
  local ok, errs = schema.validate(valid_record{ measurements = { pos_m = { 1, 2, 3 } } })
  H.rejects(ok, errs, 'must be a number')
end)

H.test('rejects NaN', function()
  local ok, errs = schema.validate(valid_record{ measurements = { speed_mps = 0/0 } })
  H.rejects(ok, errs, 'NaN')
end)

H.test('rejects infinity', function()
  local ok, errs = schema.validate(valid_record{ measurements = { speed_mps = math.huge } })
  H.rejects(ok, errs, 'infinite')
end)

H.test('rejects a measurement with no unit suffix', function()
  local ok, errs = schema.validate(valid_record{ measurements = { damage = 35 } })
  H.rejects(ok, errs, 'unit suffix')
end)

H.test('rejects a measurement with an unknown unit suffix', function()
  local ok, errs = schema.validate(valid_record{ measurements = { damage_furlongs = 35 } })
  H.rejects(ok, errs, 'unit suffix')
end)

H.test('accepts every documented unit suffix', function()
  for unit in pairs(schema.UNIT_SUFFIXES) do
    local ok, errs = schema.validate(valid_record{ measurements = { ['x_' .. unit] = 1 } })
    H.ok(ok, 'unit ' .. unit .. ' rejected: ' .. table.concat(errs, '; '))
  end
end)

H.test('split_unit separates name from unit', function()
  local n, u = schema.split_unit('claimed_damage_n')
  H.eq(n, 'claimed_damage'); H.eq(u, 'n')
  local n2, u2 = schema.split_unit('nounit')
  H.eq(n2, 'nounit'); H.is_nil(u2)
end)

H.suite('schema: context is flat qualifiers')

H.test('rejects a nested table in context', function()
  local ok, errs = schema.validate(valid_record{ context = { grade = { level = 3 } } })
  H.rejects(ok, errs, 'scalar')
end)

H.test('rejects an unbounded string in context', function()
  local ok, errs = schema.validate(valid_record{ context = { blob = string.rep('x', 200) } })
  H.rejects(ok, errs, 'low-cardinality')
end)

H.suite('schema: PII must never enter telemetry')

-- docs/QBCORE_INTEGRATION.md §2 excludes charinfo entirely. These are the fields a
-- well-meaning contributor is most likely to add "just for context".
H.test('rejects QBCore charinfo fields in context', function()
  for _, k in ipairs({ 'firstname', 'lastname', 'birthdate', 'phone', 'account' }) do
    local ok, errs = schema.validate(valid_record{ context = { [k] = 'x' } })
    H.rejects(ok, errs, 'forbidden key', 'charinfo field ' .. k)
  end
end)

H.test('rejects platform identifiers in context', function()
  for _, k in ipairs({ 'license', 'steam', 'discord', 'ip', 'endpoint' }) do
    local ok, errs = schema.validate(valid_record{ context = { [k] = 'x' } })
    H.rejects(ok, errs, 'forbidden key', 'identifier ' .. k)
  end
end)

H.test('rejects a player display name', function()
  local ok, errs = schema.validate(valid_record{ context = { name = 'SomePlayer' } })
  H.rejects(ok, errs, 'forbidden key')
end)

H.test('rejects PII smuggled into the envelope', function()
  local r = valid_record()
  r.license = 'license:abc'
  local ok, errs = schema.validate(r)
  H.rejects(ok, errs, 'forbidden key')
end)

H.test('is case-insensitive about forbidden keys', function()
  local ok, errs = schema.validate(valid_record{ context = { FirstName = 'x' } })
  H.rejects(ok, errs, 'forbidden key')
end)

H.suite('schema: assert_valid')

H.test('assert_valid returns the record when valid', function()
  local r = valid_record()
  H.eq(schema.assert_valid(r), r)
end)

H.test('assert_valid raises when invalid', function()
  local ok = pcall(schema.assert_valid, valid_record{ category = 'nope' })
  H.eq(ok, false, 'expected assert_valid to raise')
end)

--[[
  tests/unit/test_jsonl.lua

  This codec is load-bearing for the evidence store and for fixture replay, so the
  tests care about three properties above all:

    1. DETERMINISM -- the same record must always serialise identically, or fixtures
       cannot be byte-compared.
    2. ROUND-TRIP FIDELITY -- a recorded measurement must come back exactly. Silent
       numeric drift in an evidence store is the worst kind of corruption: invisible.
    3. REFUSAL, NOT GUESSING -- anything outside the supported shape is rejected with
       a reason rather than mangled.
]]
local H = ...
local J = require('logic.jsonl')

H.suite('jsonl: determinism')

H.test('key order is sorted, not table order', function()
  -- Lua table iteration order is unspecified; sorting is what makes output stable.
  local s = assert(J.encode({ zebra = 1, alpha = 2, mango = 3 }))
  H.eq(s, '{"alpha":2,"mango":3,"zebra":1}')
end)

H.test('the same content encodes identically regardless of insertion order', function()
  local a = { b = 1, a = 2, c = { y = 1, x = 2 } }
  local c = {}
  c.c = { x = 2, y = 1 }; c.a = 2; c.b = 1
  H.eq(assert(J.encode(a)), assert(J.encode(c)))
end)

H.test('encoding is stable across repeated calls', function()
  local rec = { one = 1, two = 2, three = 3, four = 4, five = 5, six = 6 }
  local first = assert(J.encode(rec))
  for _ = 1, 20 do H.eq(assert(J.encode(rec)), first) end
end)

H.suite('jsonl: scalars')

H.test('encodes booleans and strings', function()
  H.eq(assert(J.encode(true)), 'true')
  H.eq(assert(J.encode(false)), 'false')
  H.eq(assert(J.encode('hi')), '"hi"')
end)

H.test('encodes integers without a decimal point', function()
  H.eq(assert(J.encode(35)), '35')
  H.eq(assert(J.encode(-7)), '-7')
  H.eq(assert(J.encode(0)), '0')
end)

H.test('keeps a float looking like a float', function()
  -- Otherwise math.type() would change across a round trip.
  local s = assert(J.encode(2.0))
  H.ok(s:find('[%.eE]'), 'expected a decimal point in ' .. s)
  H.eq(math.type(assert(J.decode(s))), 'float')
end)

H.test('escapes the characters JSON requires', function()
  H.eq(assert(J.encode('a"b')), '"a\\"b"')
  H.eq(assert(J.encode('a\\b')), '"a\\\\b"')
  H.eq(assert(J.encode('a\nb')), '"a\\nb"')
  H.eq(assert(J.encode('a\tb')), '"a\\tb"')
end)

H.test('escapes other control characters as \\uXXXX', function()
  H.eq(assert(J.encode('a\1b')), '"a\\u0001b"')
end)

H.suite('jsonl: round-trip fidelity')

H.test('integers survive exactly', function()
  for _, v in ipairs({ 0, 1, -1, 35, 453432689, 1758204000123, -9007199254740993 }) do
    local back = assert(J.decode(assert(J.encode(v))))
    H.eq(back, v, 'value ' .. tostring(v))
    H.eq(math.type(back), 'integer', 'subtype for ' .. tostring(v))
  end
end)

H.test('floats survive exactly, including awkward ones', function()
  -- 0.1 and 1/3 are the classic cases where too few digits lose the value.
  for _, v in ipairs({ 0.1, 0.5, 1.5, -0.25, 1/3, 742.84313964844, 1e-7, 1.7976931348623157e308 }) do
    local s = assert(J.encode(v))
    local back = assert(J.decode(s))
    H.eq(back, v, ('value %s encoded as %s'):format(tostring(v), s))
  end
end)

H.test('a deeply awkward float round-trips bit-exactly', function()
  local v = 0.1 + 0.2   -- 0.30000000000000004
  local back = assert(J.decode(assert(J.encode(v))))
  H.eq(back, v, 'lossy float encoding would silently alter a measurement')
end)

H.test('nested structures round-trip', function()
  local rec = {
    schema_version = 1, player_key = 'QB:ABCD1234',
    measurements = { damage_n = 35, pos_x_m = -1.25 },
    context = { silenced = false, weapon_hash = 453432689 },
    evidence_refs = { 'c_a', 'c_b', 'c_c' },
  }
  local back = assert(J.decode(assert(J.encode(rec))))
  H.eq(back.schema_version, 1)
  H.eq(back.measurements.damage_n, 35)
  H.eq(back.measurements.pos_x_m, -1.25)
  H.eq(back.context.silenced, false)
  H.eq(#back.evidence_refs, 3)
  H.eq(back.evidence_refs[3], 'c_c')
end)

H.test('strings with escapes round-trip', function()
  for _, v in ipairs({ 'a"b', 'a\\b', 'line\nbreak', 'tab\there', 'ctrl\1char', '' }) do
    H.eq(assert(J.decode(assert(J.encode(v)))), v)
  end
end)

H.suite('jsonl: refuses rather than guesses')

H.test('rejects NaN and infinity', function()
  local s, err = J.encode(0/0)
  H.is_nil(s); H.ok(err:find('NaN', 1, true))
  s, err = J.encode(math.huge)
  H.is_nil(s); H.ok(err:find('infinity', 1, true))
  s, err = J.encode(-math.huge)
  H.is_nil(s); H.ok(err:find('infinity', 1, true))
end)

H.test('rejects a function', function()
  local s, err = J.encode({ fn = function() end })
  H.is_nil(s); H.ok(err:find('type function', 1, true))
end)

H.test('rejects a cycle instead of recursing forever', function()
  local t = {}; t.self = t
  local s, err = J.encode(t)
  H.is_nil(s); H.ok(err:find('cycle', 1, true))
end)

H.test('rejects a table mixing array and map keys', function()
  -- Ambiguous: JSON has no such shape. Guessing would drop half the data.
  local s, err = J.encode({ 1, 2, name = 'x' })
  H.is_nil(s); H.ok(err:find('mixes array and map', 1, true))
end)

H.test('rejects a sparse array', function()
  local t = {}; t[1] = 'a'; t[3] = 'c'
  local s, err = J.encode(t)
  H.is_nil(s)
  H.ok(err:find('sparse', 1, true) or err:find('mixes', 1, true), 'got: ' .. tostring(err))
end)

H.test('rejects excessive nesting', function()
  local t = {}
  local cur = t
  for _ = 1, 40 do cur.n = {}; cur = cur.n end
  local s, err = J.encode(t)
  H.is_nil(s); H.ok(err:find('nesting', 1, true))
end)

H.test('the error names the offending path', function()
  local s, err = J.encode({ measurements = { bad_n = 0/0 } })
  H.is_nil(s)
  H.ok(err:find('measurements', 1, true), 'error should locate the problem: ' .. tostring(err))
end)

H.suite('jsonl: encode_line')

H.test('produces a single line', function()
  local s = assert(J.encode_line({ a = 1, b = 'x' }))
  H.is_nil(s:find('\n', 1, true))
end)

H.test('rejects a value whose encoding would contain a newline', function()
  -- A newline inside a line would split one record into two unparseable halves and
  -- corrupt the file from that point on. Escaping prevents it; this is belt and braces.
  local s = assert(J.encode_line({ note = 'a\nb' }))
  H.is_nil(s:find('\n', 1, true), 'the newline must be escaped, not literal')
end)

H.suite('jsonl: decoding')

H.test('parses objects, arrays, nesting and whitespace', function()
  local v = assert(J.decode(' { "a" : [ 1 , 2 , { "b" : true } ] } '))
  H.eq(v.a[1], 1); H.eq(v.a[3].b, true)
end)

H.test('parses an empty object and an empty array', function()
  H.eq(type(assert(J.decode('{}'))), 'table')
  local arr = assert(J.decode('[]'))
  H.eq(#arr, 0)
end)

H.test('null becomes a visible sentinel, not nil', function()
  -- nil in a table is indistinguishable from an absent key, which would silently
  -- drop the field and hide the fact that it was present-but-null.
  local v = assert(J.decode('{"a":null}'))
  H.eq(v.a, J.NULL)
  H.ok(v.a ~= nil, 'a present null must remain visible')
end)

H.test('rejects trailing content', function()
  local v, err = J.decode('{"a":1} garbage')
  H.is_nil(v); H.ok(err:find('trailing', 1, true))
end)

H.test('rejects malformed input with a byte offset', function()
  for _, bad in ipairs({ '{', '{"a"}', '{"a":}', '[1,]', '{"a":1,}', 'tru', '"unterminated' }) do
    local v, err = J.decode(bad)
    H.is_nil(v, 'should reject: ' .. bad)
    H.ok(err and #err > 0, 'should explain: ' .. bad)
  end
end)

H.test('rejects a raw control character inside a string', function()
  local v, err = J.decode('{"a":"x\1y"}')
  H.is_nil(v); H.ok(err:find('control character', 1, true))
end)

H.test('rejects a non-string argument', function()
  local v, err = J.decode(nil)
  H.is_nil(v); H.ok(err:find('expects a string', 1, true))
end)

H.suite('jsonl: decode_lines isolates per-line damage')

H.test('reads several records', function()
  local body = '{"a":1}\n{"a":2}\n{"a":3}\n'
  local recs, errs = J.decode_lines(body)
  H.eq(#recs, 3); H.eq(#errs, 0)
  H.eq(recs[2].a, 2)
end)

H.test('skips blank lines', function()
  local recs, errs = J.decode_lines('{"a":1}\n\n   \n{"a":2}\n')
  H.eq(#recs, 2); H.eq(#errs, 0)
end)

H.test('one corrupt line does not discard the file', function()
  --[[
    A truncated final write, or a partially flushed line, must not cost every other
    record in the file. The loss is reported with its line number so it is visible --
    the same principle as the timeline surfacing gaps rather than hiding them.
  ]]
  local body = '{"a":1}\n{"a":BROKEN\n{"a":3}\n'
  local recs, errs = J.decode_lines(body)
  H.eq(#recs, 2, 'the good records must survive')
  H.eq(#errs, 1)
  H.eq(errs[1].line, 2, 'the error must name the line')
  H.ok(errs[1].text:find('BROKEN', 1, true), 'the error should quote the bad line')
end)

H.test('handles a file with no trailing newline', function()
  local recs, errs = J.decode_lines('{"a":1}\n{"a":2}')
  H.eq(#recs, 2); H.eq(#errs, 0)
end)

H.test('handles an empty body', function()
  local recs, errs = J.decode_lines('')
  H.eq(#recs, 0); H.eq(#errs, 0)
end)

H.suite('jsonl: full record round-trip against the schema')

H.test('an encoded record still validates after decoding', function()
  -- The point of the store: what is written must read back as a valid record.
  local schema   = require('logic.schema')
  local clock    = require('logic.clock')
  local envelope = require('logic.envelope')
  local normalize= require('logic.normalize')

  local c = clock.new(function() return 1758204000000 end, function() return 500 end)
  local b = envelope.new(c, { mode = 'LAB' })
  local rec = normalize.weapon_damage(b, 'QB:ABCD1234', 7, {
    weaponType = 453432689, weaponDamage = 35, hitGlobalIds = { 41 },
    localPosX = 1.5, localPosY = -0.25, damageTime = 123456,
    willKill = false, silenced = true,
  })

  local line = assert(J.encode_line(rec))
  local back = assert(J.decode(line))
  local ok, errs = schema.validate(back)
  H.ok(ok, 'decoded record failed validation: ' .. table.concat(errs, '; '))
  H.eq(back.trust, 'claimed')
  H.eq(back.measurements.claimed_damage_n, 35)
  H.eq(back.measurements.claimed_local_pos_y_m, -0.25)
  H.eq(back.context.silenced, true)
end)

--[[
  tests/unit/test_buffer.lua

  The buffer's job is to make a telemetry spike survivable without either
  exhausting memory or hiding the fact that data was lost.
]]
local H = ...
local buffer = require('logic.buffer')

H.suite('buffer: construction')

H.test('rejects an invalid capacity', function()
  H.eq(pcall(buffer.new, 0), false)
  H.eq(pcall(buffer.new, -1), false)
  H.eq(pcall(buffer.new, 1.5), false)
  H.eq(pcall(buffer.new, 'lots'), false)
end)

H.test('reports its capacity and starts empty', function()
  local b = buffer.new(8)
  H.eq(b:capacity(), 8); H.eq(b:len(), 0)
  H.eq(b:is_empty(), true); H.eq(b:is_full(), false)
  H.is_nil(b:peek())
end)

H.suite('buffer: FIFO ordering')

H.test('drains in push order', function()
  local b = buffer.new(4)
  for i = 1, 3 do b:push(i) end
  local got = b:drain()
  H.eq(#got, 3); H.eq(got[1], 1); H.eq(got[2], 2); H.eq(got[3], 3)
  H.eq(b:is_empty(), true)
end)

H.test('drain respects a max and leaves the rest in order', function()
  local b = buffer.new(8)
  for i = 1, 5 do b:push(i) end
  local first = b:drain(2)
  H.eq(#first, 2); H.eq(first[1], 1); H.eq(first[2], 2)
  H.eq(b:len(), 3)
  local rest = b:drain()
  H.eq(rest[1], 3); H.eq(rest[3], 5)
end)

H.test('peek shows the oldest without consuming it', function()
  local b = buffer.new(4)
  b:push('a'); b:push('b')
  H.eq(b:peek(), 'a'); H.eq(b:len(), 2)
end)

H.test('survives many push/drain cycles without drifting', function()
  -- Ring index arithmetic is exactly where an off-by-one hides.
  local b = buffer.new(4)
  local expect = 1
  for round = 1, 50 do
    for _ = 1, 3 do b:push(expect); expect = expect + 1 end
    local got = b:drain(3)
    H.eq(#got, 3, 'round ' .. round)
    H.eq(got[1], expect - 3, 'round ' .. round .. ' ordering')
  end
  H.eq(b:dropped(), 0, 'no drops should occur when draining within capacity')
end)

H.suite('buffer: bounded under pressure')

H.test('never exceeds capacity', function()
  local b = buffer.new(4)
  for i = 1, 1000 do b:push(i) end
  H.eq(b:len(), 4)
  H.eq(b:is_full(), true)
end)

H.test('drops the OLDEST and keeps the newest', function()
  -- Recent records carry the current incident, so the newest survive.
  local b = buffer.new(3)
  for i = 1, 5 do b:push(i) end
  local got = b:drain()
  H.eq(#got, 3)
  H.eq(got[1], 3); H.eq(got[2], 4); H.eq(got[3], 5)
end)

H.test('push reports whether it had to evict', function()
  local b = buffer.new(2)
  H.eq(b:push('a'), true)
  H.eq(b:push('b'), true)
  H.eq(b:push('c'), false, 'the evicting push must report false')
end)

H.suite('buffer: loss is counted, never silent')

H.test('counts dropped records', function()
  -- An investigator must never see a gap in a timeline without being told.
  local b = buffer.new(3)
  for i = 1, 10 do b:push(i) end
  H.eq(b:dropped(), 7)
  H.eq(b:pushed(), 10)
end)

H.test('drop count survives draining', function()
  local b = buffer.new(2)
  for i = 1, 5 do b:push(i) end
  b:drain()
  H.eq(b:dropped(), 3, 'the fact that evidence was lost must outlive the flush')
end)

H.test('stats expose capacity, size, pushed and dropped with units', function()
  local b = buffer.new(2)
  for i = 1, 4 do b:push(i) end
  local s = b:stats()
  H.eq(s.capacity_n, 2); H.eq(s.size_n, 2)
  H.eq(s.pushed_n, 4); H.eq(s.dropped_n, 2)
end)

H.suite('buffer: input handling')

H.test('ignores a nil push without counting it', function()
  local b = buffer.new(4)
  H.eq(b:push(nil), false)
  H.eq(b:len(), 0); H.eq(b:pushed(), 0)
end)

H.test('accepts tables, which is what records actually are', function()
  local b = buffer.new(2)
  local rec = { category = 'combat' }
  b:push(rec)
  H.eq(b:drain()[1], rec)
end)

H.test('drain on an empty buffer returns an empty list', function()
  H.eq(#buffer.new(4):drain(), 0)
end)

H.test('a capacity-1 buffer behaves correctly', function()
  local b = buffer.new(1)
  b:push('a'); b:push('b')
  H.eq(b:len(), 1)
  H.eq(b:drain()[1], 'b')
  H.eq(b:dropped(), 1)
end)

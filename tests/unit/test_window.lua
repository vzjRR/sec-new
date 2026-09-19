--[[
  tests/unit/test_window.lua

  This is the memory-safety component of every rate detector. Its failure modes are
  (a) unbounded growth on a busy server, and (b) silently undercounting after
  eviction, which for a rate detector means silently failing to detect.
]]
local H = ...
local W = require('logic.window')

H.suite('window: construction')

H.test('rejects a non-positive window', function()
  H.eq(pcall(W.new, { window_ms = 0 }), false)
  H.eq(pcall(W.new, { window_ms = -1 }), false)
  H.eq(pcall(W.new, { window_ms = 'soon' }), false)
end)

H.test('reports its configuration', function()
  local w = W.new{ window_ms = 5000, max_keys = 10, max_events_per_key = 4 }
  H.eq(w:window_ms(), 5000)
  local s = w:stats()
  H.eq(s.max_keys, 10); H.eq(s.max_events_per_key, 4); H.eq(s.keys_n, 0)
end)

H.suite('window: counting within the window')

H.test('counts events for a key', function()
  local w = W.new{ window_ms = 1000 }
  H.eq(w:add('p1', 100), 1)
  H.eq(w:add('p1', 200), 2)
  H.eq(w:add('p1', 300), 3)
  H.eq(w:count('p1', 300), 3)
end)

H.test('keys are independent', function()
  local w = W.new{ window_ms = 1000 }
  w:add('p1', 100); w:add('p1', 110); w:add('p2', 120)
  H.eq(w:count('p1', 120), 2)
  H.eq(w:count('p2', 120), 1)
end)

H.test('an unknown key counts zero', function()
  H.eq(W.new{ window_ms = 1000 }:count('nobody', 100), 0)
end)

H.test('events outside the window expire', function()
  local w = W.new{ window_ms = 1000 }
  w:add('p1', 100); w:add('p1', 200)
  H.eq(w:count('p1', 500), 2)
  H.eq(w:count('p1', 1150), 1, 'the event at 100 is now outside a 1000ms window')
  H.eq(w:count('p1', 2000), 0)
end)

H.test('expiry happens on add as well as count', function()
  -- window 1000ms, adding at t=1500 means the cutoff is 500: both earlier events
  -- are outside it, so the returned count is just the new one.
  local w = W.new{ window_ms = 1000 }
  w:add('p1', 100); w:add('p1', 200)
  H.eq(w:add('p1', 1500), 1)

  -- And a partial case, so this covers expiry rather than just wholesale clearing:
  -- at t=1150 the cutoff is 150, so the 200 survives and the 100 does not.
  local w2 = W.new{ window_ms = 1000 }
  w2:add('p2', 100); w2:add('p2', 200)
  H.eq(w2:add('p2', 1150), 2, 'the 200 and the 1150 are both in window')
end)

H.test('an event exactly on the boundary is retained', function()
  local w = W.new{ window_ms = 1000 }
  w:add('p1', 100)
  H.eq(w:count('p1', 1100), 1, 'cutoff is inclusive at exactly window_ms')
end)

H.test('tracks the last event time', function()
  local w = W.new{ window_ms = 1000 }
  w:add('p1', 100); w:add('p1', 250)
  H.eq(w:last('p1'), 250)
  H.is_nil(w:last('nobody'))
end)

H.suite('window: bounded events per key')

H.test('never exceeds max_events_per_key', function()
  local w = W.new{ window_ms = 100000, max_events_per_key = 3 }
  for i = 1, 50 do w:add('p1', i) end
  H.eq(w:count('p1', 50), 3)
end)

H.test('keeps the MOST RECENT events when saturated', function()
  --[[
    Dropping the newest instead would make a sustained burst look like it had
    stopped -- the opposite of what a rate detector needs to see.
  ]]
  local w = W.new{ window_ms = 100000, max_events_per_key = 3 }
  for i = 1, 10 do w:add('p1', i * 10) end
  H.eq(w:last('p1'), 100)
  H.eq(w:count('p1', 100), 3)
end)

H.test('counts dropped events', function()
  local w = W.new{ window_ms = 100000, max_events_per_key = 3 }
  for i = 1, 10 do w:add('p1', i) end
  H.eq(w:stats().evicted_events_n, 7)
end)

H.suite('window: bounded key count')

H.test('never exceeds max_keys', function()
  local w = W.new{ window_ms = 100000, max_keys = 5 }
  for i = 1, 100 do w:add('p' .. i, i) end
  H.eq(w:stats().keys_n, 5)
end)

H.test('evicts the least recently touched key', function()
  local w = W.new{ window_ms = 100000, max_keys = 3 }
  w:add('old', 10)
  w:add('mid', 20)
  w:add('new', 30)
  w:add('mid', 40)          -- refresh mid so 'old' is now the LRU
  w:add('fourth', 50)       -- forces an eviction
  H.eq(w:count('old', 50), 0, 'the least recently touched key should be gone')
  H.ok(w:count('mid', 50) > 0, 'a recently touched key must survive')
  H.ok(w:count('new', 50) > 0)
end)

H.test('counts evicted keys and the events lost with them', function()
  local w = W.new{ window_ms = 100000, max_keys = 2 }
  w:add('a', 1); w:add('a', 2); w:add('a', 3)   -- 3 events on 'a'
  w:add('b', 4)
  w:add('c', 5)                                  -- evicts 'a'
  local s = w:stats()
  H.eq(s.evicted_keys_n, 1)
  H.eq(s.evicted_events_n, 3, 'the events lost with the key must be counted')
end)

H.suite('window: loss must be visible to the detector')

H.test('a clean window reports no loss', function()
  local w = W.new{ window_ms = 1000 }
  w:add('p1', 100)
  H.eq(w:lossy(), false)
end)

H.test('event saturation makes the window lossy', function()
  --[[
    A count taken after eviction is a FLOOR, not a measurement. A detector reading it
    as exact would understate the real rate -- a silent failure to detect.
  ]]
  local w = W.new{ window_ms = 100000, max_events_per_key = 2 }
  for i = 1, 5 do w:add('p1', i) end
  H.eq(w:lossy(), true)
end)

H.test('key eviction makes the window lossy', function()
  local w = W.new{ window_ms = 100000, max_keys = 1 }
  w:add('a', 1); w:add('b', 2)
  H.eq(w:lossy(), true)
end)

H.suite('window: housekeeping')

H.test('prune drops keys idle beyond the window', function()
  local w = W.new{ window_ms = 1000 }
  w:add('stale', 100)
  w:add('fresh', 5000)
  H.eq(w:prune(5000), 1)
  H.eq(w:stats().keys_n, 1)
  H.ok(w:count('fresh', 5000) > 0)
end)

H.test('prune does not count as loss -- the events had already expired', function()
  local w = W.new{ window_ms = 1000 }
  w:add('stale', 100)
  w:prune(5000)
  H.eq(w:lossy(), false, 'expiry is not eviction; only forced drops are loss')
end)

H.test('prune tolerates a bad argument', function()
  H.eq(W.new{ window_ms = 1000 }:prune(nil), 0)
end)

H.test('forget removes one key', function()
  local w = W.new{ window_ms = 1000 }
  w:add('p1', 100)
  H.eq(w:forget('p1'), true)
  H.eq(w:count('p1', 100), 0)
  H.eq(w:forget('p1'), false)
  H.eq(w:stats().keys_n, 0)
end)

H.suite('window: input handling')

H.test('ignores malformed input without creating a key', function()
  local w = W.new{ window_ms = 1000 }
  H.eq(w:add(nil, 100), 0)
  H.eq(w:add('p1', nil), 0)
  H.eq(w:add(42, 100), 0)
  H.eq(w:stats().keys_n, 0)
end)

H.test('survives a long realistic run without unbounded growth', function()
  -- 64 players x 4 entity types, 20k events: the table must stay bounded.
  local w = W.new{ window_ms = 60000, max_keys = 256, max_events_per_key = 128 }
  local t = 0
  for i = 1, 20000 do
    t = t + 3
    w:add(('p%d:t%d'):format(i % 64, i % 4), t)
  end
  local s = w:stats()
  H.ok(s.keys_n <= 256, 'keys must stay bounded, got ' .. s.keys_n)
  H.ok(w:count('p1:t1', t) <= 128, 'per-key events must stay bounded')
end)

--[[
  tests/unit/test_evidence.lua

  The store's defining property is that LOSS IS ALWAYS ACCOUNTED FOR. A store
  reporting "12 records" after 3 failed writes is worse than no store, because an
  investigator would conclude the missing behaviour never happened. These tests
  attack that property directly.
]]
local H = ...
local evidence = require('logic.evidence')
local J        = require('logic.jsonl')

local function memory_backend(opts)
  opts = opts or {}
  local files = {}
  local b = {
    files = files,
    append = function(path, line)
      if opts.fail_on and path:find(opts.fail_on, 1, true) then
        return false, 'simulated write failure'
      end
      files[path] = (files[path] or '') .. line .. '\n'
      return true
    end,
  }
  -- An explicit `if`: `opts.write_only and nil or function() end` would always yield
  -- the function, since Lua's `and` cannot produce nil. The write-only case would
  -- then never have been exercised at all.
  if not opts.write_only then
    b.read = function(path)
      local body = files[path]
      if body == nil then return nil, 'no such file' end
      return body
    end
  end
  return b
end

local function store(backend, opts)
  opts = opts or {}
  opts.root = opts.root or 'ev'
  opts.day  = opts.day or function() return '2026-09-18' end
  return evidence.new(backend,
    { encode_line = J.encode_line, decode_lines = J.decode_lines }, opts)
end

H.suite('evidence: construction')

H.test('requires a backend with append', function()
  H.eq(pcall(evidence.new, nil, { encode_line = J.encode_line }), false)
  H.eq(pcall(evidence.new, {}, { encode_line = J.encode_line }), false)
end)

H.test('requires an encoder', function()
  H.eq(pcall(evidence.new, { append = function() end }, {}), false)
end)

H.suite('evidence: path derivation')

H.test('files by kind, category and UTC day', function()
  local s = store(memory_backend())
  H.eq(s:path_for('telemetry', 'combat'), 'ev/2026-09-18/telemetry-combat.jsonl')
  H.eq(s:path_for('incident', 'snapshot'), 'ev/2026-09-18/incident-snapshot.jsonl')
end)

H.test('sanitises a hostile category instead of trusting it', function()
  --[[
    `category` reaches the store from a record, and records originate near
    attacker-influenced data. A category containing '../' would otherwise choose
    where a write lands -- a path traversal bug inside a security resource.
  ]]
  local s = store(memory_backend())
  local p = s:path_for('telemetry', '../../etc/passwd')
  H.is_nil(p:find('..', 1, true), 'traversal must not survive: ' .. p)
  H.ok(p:find('unsafe_category', 1, true), 'got ' .. p)
end)

H.test('sanitises a hostile kind', function()
  local s = store(memory_backend())
  local p = s:path_for('../evil', 'combat')
  H.ok(p:find('unsafe_kind', 1, true), 'got ' .. p)
end)

H.test('handles a nil category', function()
  local s = store(memory_backend())
  H.ok(s:path_for('telemetry', nil):find('unknown', 1, true))
end)

H.suite('evidence: appending')

H.test('writes a record and counts it', function()
  local b = memory_backend()
  local s = store(b)
  local ok, err, path = s:append_record({ category = 'combat', a = 1 })
  H.eq(ok, true); H.is_nil(err)
  H.eq(path, 'ev/2026-09-18/telemetry-combat.jsonl')
  H.eq(s:stats().written_n, 1)
  H.ok(b.files[path]:find('"a":1', 1, true))
end)

H.test('appends, never overwrites', function()
  local b = memory_backend()
  local s = store(b)
  s:append_record({ category = 'combat', a = 1 })
  s:append_record({ category = 'combat', a = 2 })
  local body = b.files['ev/2026-09-18/telemetry-combat.jsonl']
  H.ok(body:find('"a":1', 1, true), 'the first record must survive the second')
  H.ok(body:find('"a":2', 1, true))
end)

H.test('files detections by detector domain', function()
  local b = memory_backend()
  local s = store(b)
  local _, _, path = s:append_detection({ detector_id = 'combat.dead_shooter' })
  H.eq(path, 'ev/2026-09-18/detection-combat.jsonl')
end)

H.test('incident snapshots accumulate rather than replace', function()
  --[[
    Append-only means a status change produces a NEW snapshot. Reading back gives the
    full history of how the assessment evolved -- which is exactly what someone
    reviewing a disputed conclusion needs, and what an overwrite would destroy.
  ]]
  local b = memory_backend()
  local s = store(b)
  s:append_incident_snapshot({ id = 'INC-1', status = 'OBSERVING' })
  s:append_incident_snapshot({ id = 'INC-1', status = 'INVESTIGATING' })
  s:append_incident_snapshot({ id = 'INC-1', status = 'DISMISSED' })
  local r = s:read('incident', 'snapshot')
  H.eq(#r.records, 3)
  H.eq(r.records[1].status, 'OBSERVING')
  H.eq(r.records[3].status, 'DISMISSED')
end)

H.test('rejects a non-table', function()
  local s = store(memory_backend())
  H.eq((s:append_record('nope')), false)
  H.eq((s:append_detection(42)), false)
  H.eq((s:append_incident_snapshot(nil)), false)
end)

H.suite('evidence: loss is counted, never silent')

H.test('an encode failure is counted and explained', function()
  local s = store(memory_backend())
  local ok, err = s:append_record({ category = 'combat', bad = 0/0 })
  H.eq(ok, false)
  H.ok(err:find('encode failed', 1, true))
  local st = s:stats()
  H.eq(st.encode_failed_n, 1)
  H.eq(st.written_n, 0)
  H.eq(st.lost_n, 1)
end)

H.test('a backend failure is counted and explained', function()
  local s = store(memory_backend({ fail_on = 'telemetry-combat' }))
  local ok, err = s:append_record({ category = 'combat', a = 1 })
  H.eq(ok, false)
  H.ok(err:find('backend failed', 1, true))
  local st = s:stats()
  H.eq(st.backend_failed_n, 1)
  H.eq(st.lost_n, 1)
end)

H.test('is_complete goes false the moment anything is lost', function()
  local s = store(memory_backend({ fail_on = 'telemetry-combat' }))
  H.eq((s:is_complete()), true, 'an empty store is complete')
  s:append_record({ category = 'combat', a = 1 })
  local ok, reason = s:is_complete()
  H.eq(ok, false)
  H.ok(reason:find('incomplete record', 1, true),
    'the reason must warn that analysis is working from an incomplete record')
end)

H.test('partial success still reports the loss', function()
  -- The dangerous case: some writes succeed, so the store looks healthy.
  local s = store(memory_backend({ fail_on = 'telemetry-movement' }))
  s:append_record({ category = 'combat', a = 1 })
  s:append_record({ category = 'movement', a = 2 })
  s:append_record({ category = 'combat', a = 3 })
  local st = s:stats()
  H.eq(st.written_n, 2)
  H.eq(st.lost_n, 1)
  H.eq((s:is_complete()), false)
end)

H.test('failures record what was lost and where', function()
  local s = store(memory_backend({ fail_on = 'telemetry-combat' }))
  s:append_record({ category = 'combat', a = 1 })
  local f = s:stats().failures
  H.eq(#f, 1)
  H.ok(f[1].reason:find('backend', 1, true))
  H.ok(f[1].path:find('telemetry-combat', 1, true))
end)

H.test('the failure list is bounded so a broken disk cannot exhaust memory', function()
  local s = store(memory_backend({ fail_on = 'telemetry' }))
  for i = 1, 200 do s:append_record({ category = 'combat', a = i }) end
  local st = s:stats()
  H.eq(st.backend_failed_n, 200, 'every failure must still be COUNTED')
  H.ok(#st.failures <= 50, 'but the detail list must be bounded')
  H.eq(st.failures_truncated, true, 'and truncation must be declared')
end)

H.test('counts by kind', function()
  local s = store(memory_backend())
  s:append_record({ category = 'combat' })
  s:append_record({ category = 'movement' })
  s:append_detection({ detector_id = 'events.contract' })
  local bk = s:stats().by_kind
  H.eq(bk.telemetry, 2)
  H.eq(bk.detection, 1)
end)

H.suite('evidence: retrieval')

H.test('reads back what was written', function()
  local s = store(memory_backend())
  s:append_record({ category = 'combat', seq = 1, a = 'x' })
  s:append_record({ category = 'combat', seq = 2, a = 'y' })
  local r = s:read('telemetry', 'combat')
  H.eq(#r.records, 2)
  H.eq(r.records[2].a, 'y')
  H.eq(r.complete, true)
  H.is_nil(r.note)
end)

H.test('a missing file reads as incomplete with a reason, not as empty', function()
  -- "no data" and "could not read the data" must not look the same.
  local r = store(memory_backend()):read('telemetry', 'combat')
  H.eq(#r.records, 0)
  H.eq(r.complete, false)
  H.ok(r.note:find('read failed', 1, true))
end)

H.test('a corrupt line is reported and the rest survive', function()
  local b = memory_backend()
  local s = store(b)
  s:append_record({ category = 'combat', a = 1 })
  local path = s:path_for('telemetry', 'combat')
  b.files[path] = b.files[path] .. '{"a":TRUNCATED\n'
  s:append_record({ category = 'combat', a = 3 })
  local r = s:read('telemetry', 'combat')
  H.eq(#r.records, 2, 'the good records must survive')
  H.eq(#r.corrupt, 1)
  H.eq(r.complete, false)
  H.ok(r.note:find('incomplete', 1, true))
end)

H.test('a write-only backend says retrieval is unavailable', function()
  local r = store(memory_backend({ write_only = true })):read('telemetry', 'combat')
  H.eq(r.complete, false)
  H.ok(r.note:find('write-only', 1, true))
end)

H.suite('evidence: integrity digest')

H.test('a digest appears once something is written', function()
  local s = store(memory_backend())
  local path = s:path_for('telemetry', 'combat')
  H.is_nil(s:digest(path))
  s:append_record({ category = 'combat', a = 1 })
  H.eq(#s:digest(path), 16, 'expected a 16-hex-digit digest')
end)

H.test('the digest is order-sensitive, so it is a chain not a sum', function()
  local a = store(memory_backend())
  a:append_record({ category = 'combat', seq = 1 })
  a:append_record({ category = 'combat', seq = 2 })

  local b = store(memory_backend())
  b:append_record({ category = 'combat', seq = 2 })
  b:append_record({ category = 'combat', seq = 1 })

  local p = 'ev/2026-09-18/telemetry-combat.jsonl'
  H.ok(a:digest(p) ~= b:digest(p), 'reordering the file must change the digest')
end)

H.test('verify passes on an untouched file', function()
  local s = store(memory_backend())
  s:append_record({ category = 'combat', a = 1 })
  s:append_record({ category = 'combat', a = 2 })
  local ok, detail = s:verify('telemetry', 'combat', s:digest(s:path_for('telemetry','combat')))
  H.eq(ok, true)
  H.ok(detail:find('matches', 1, true))
end)

H.test('verify catches a modified line', function()
  local b = memory_backend()
  local s = store(b)
  s:append_record({ category = 'combat', a = 1 })
  local path = s:path_for('telemetry', 'combat')
  local expected = s:digest(path)
  b.files[path] = b.files[path]:gsub('"a":1', '"a":9')
  local ok, detail = s:verify('telemetry', 'combat', expected)
  H.eq(ok, false)
  H.ok(detail:find('mismatch', 1, true))
  H.ok(detail:find('modified, truncated', 1, true))
end)

H.test('verify catches a truncated file', function()
  local b = memory_backend()
  local s = store(b)
  s:append_record({ category = 'combat', a = 1 })
  s:append_record({ category = 'combat', a = 2 })
  local path = s:path_for('telemetry', 'combat')
  local expected = s:digest(path)
  b.files[path] = b.files[path]:gsub('.*\n(.*\n)$', '%1')  -- drop the first line
  H.eq((s:verify('telemetry', 'combat', expected)), false)
end)

H.test('verify with no expected value just reports the digest', function()
  local s = store(memory_backend())
  s:append_record({ category = 'combat', a = 1 })
  local ok, detail = s:verify('telemetry', 'combat', nil)
  H.eq(ok, true)
  H.ok(detail:find('no expected value', 1, true))
end)

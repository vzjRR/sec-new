--[[
  security-forensics / logic / evidence.lua

  PURE LUA. The evidence store: append-only, accountable, retrievable.

  Persistence is INJECTED (`backend.append(path, line)` / `backend.read(path)`), so
  the store's logic -- path derivation, write accounting, retrieval, integrity -- is
  fully testable in CI while the actual file I/O stays in an adapter (C2).

  ---------------------------------------------------------------------------
  THE PROPERTY THAT MATTERS: LOSS IS ALWAYS ACCOUNTED FOR.

  Three different things can cost evidence, and all three are counted rather than
  swallowed:

    * an encode failure  -- the record could not be serialised
    * a backend failure  -- the write was rejected (disk full, permissions)
    * a corrupt line     -- a partial write makes one line unparseable on read

  Every one is counted and surfaced in `stats()` and in a retrieval result. A store
  that reports "12 records" when 3 writes failed is worse than no store, because an
  investigator would conclude the missing behaviour never happened. This is the same
  principle as the ring buffer counting drops and the timeline surfacing gaps.
  ---------------------------------------------------------------------------
]]

local M = {}

M.KIND_TELEMETRY = 'telemetry'
M.KIND_DETECTION = 'detection'
M.KIND_INCIDENT  = 'incident'

local Store = {}
Store.__index = Store

--[[
  Integrity digest: FNV-1a, 64-bit, chained over each line.

  WHAT THIS IS AND IS NOT, stated plainly because the distinction matters:

    IT DETECTS  accidental corruption -- a truncated write, a partially flushed
                line, a naive hand edit, bit rot, a file concatenated twice.
    IT DOES NOT provide tamper-proofing. FNV-1a is not cryptographic, and anyone who
                can write the evidence file can recompute the digest.

  That is an acceptable trade here: the security model already excludes host
  compromise (docs/SECURITY_MODEL.md §1, A8), and accidental corruption is the
  failure that actually happens. Claiming cryptographic integrity from this would be
  exactly the kind of overstatement this project exists to avoid. If real
  tamper-evidence is ever needed, it requires signing off-host, not a better checksum.
]]
local FNV_OFFSET = 0xcbf29ce484222325
local FNV_PRIME  = 0x100000001b3

local function fnv1a(seed, text)
  local h = seed
  for i = 1, #text do
    h = h ~ text:byte(i)
    h = h * FNV_PRIME       -- wraps as Lua 5.4 integer arithmetic, which is what we want
  end
  return h
end

--- @param backend { append = fn(path, line) -> ok, err ; read = fn(path) -> body, err }
-- @param deps    { encode_line = fn(v) -> str, err ; decode_lines = fn(body) -> recs, errs }
-- @param opts    { root = 'evidence', day = fn() -> '2026-09-18' }
function M.new(backend, deps, opts)
  assert(type(backend) == 'table', 'evidence: backend required')
  assert(type(backend.append) == 'function', 'evidence: backend.append required')
  assert(type(deps) == 'table' and type(deps.encode_line) == 'function',
    'evidence: deps.encode_line required')
  opts = opts or {}

  return setmetatable({
    _backend = backend,
    _deps    = deps,
    _root    = opts.root or 'evidence',
    _day     = opts.day or function() return '0000-00-00' end,
    _counts  = {
      written_n = 0, encode_failed_n = 0, backend_failed_n = 0,
      by_kind = {},
    },
    _digests = {},   -- [path] = running digest
    _failures = {},  -- bounded record of what was lost, for the health report
  }, Store)
end

--[[
  Path derivation. One file per kind per category per UTC day
  (docs/TELEMETRY_SCHEMA.md §8).

  `category` is sanitised rather than trusted: it reaches here from a record, and a
  record's fields originate near attacker-influenced data. A category containing
  `../` would otherwise choose the path a write lands on -- a path-traversal bug in a
  security resource, which would be an embarrassing way to be compromised.
]]
local SAFE_SEGMENT = '^[%w_%-]+$'

function Store:path_for(kind, category)
  local k = tostring(kind or 'unknown')
  local c = tostring(category or 'unknown')
  if not k:match(SAFE_SEGMENT) then k = 'unsafe_kind' end
  if not c:match(SAFE_SEGMENT) then c = 'unsafe_category' end
  return string.format('%s/%s/%s-%s.jsonl', self._root, self._day(), k, c)
end

local MAX_TRACKED_FAILURES = 50

function Store:_record_failure(kind, path, reason)
  if #self._failures < MAX_TRACKED_FAILURES then
    self._failures[#self._failures + 1] = { kind = kind, path = path, reason = reason }
  end
end

--- Append one value. Returns ok, err, path.
function Store:append(kind, category, value)
  local line, enc_err = self._deps.encode_line(value)
  if not line then
    self._counts.encode_failed_n = self._counts.encode_failed_n + 1
    self:_record_failure(kind, nil, 'encode: ' .. tostring(enc_err))
    return false, 'encode failed: ' .. tostring(enc_err), nil
  end

  local path = self:path_for(kind, category)
  local ok, back_err = self._backend.append(path, line)
  if not ok then
    self._counts.backend_failed_n = self._counts.backend_failed_n + 1
    self:_record_failure(kind, path, 'backend: ' .. tostring(back_err))
    return false, 'backend failed: ' .. tostring(back_err), path
  end

  self._counts.written_n = self._counts.written_n + 1
  self._counts.by_kind[kind] = (self._counts.by_kind[kind] or 0) + 1
  self._digests[path] = fnv1a(self._digests[path] or FNV_OFFSET, line)
  return true, nil, path
end

--- Append a telemetry record, filed by its own category.
function Store:append_record(record)
  if type(record) ~= 'table' then return false, 'record must be a table' end
  return self:append(M.KIND_TELEMETRY, record.category, record)
end

--- Append a detection result, filed by detector id prefix (its domain).
function Store:append_detection(result)
  if type(result) ~= 'table' then return false, 'result must be a table' end
  local domain = tostring(result.detector_id or 'unknown'):match('^([%w_]+)') or 'unknown'
  return self:append(M.KIND_DETECTION, domain, result)
end

--[[
  Persist an incident SNAPSHOT.

  Snapshots, not updates: the store is append-only, so an incident that changes status
  produces a new snapshot rather than overwriting the old one. Reading back gives the
  full history of how the incident's assessment evolved, which is exactly what an
  investigator reviewing a disputed conclusion needs -- and what an overwrite would
  destroy.
]]
function Store:append_incident_snapshot(incident_summary)
  if type(incident_summary) ~= 'table' then return false, 'summary must be a table' end
  return self:append(M.KIND_INCIDENT, 'snapshot', incident_summary)
end

--[[
  Read back a kind/category.

  @return result table {
            records, corrupt (list of {line, err, text}),
            path, complete (boolean), note (string|nil)
          }

  `complete` is false when any line failed to parse. A caller must treat that as
  "insufficient evidence", never as "this is all that happened".
]]
function Store:read(kind, category)
  local path = self:path_for(kind, category)
  if type(self._backend.read) ~= 'function' then
    return { records = {}, corrupt = {}, path = path, complete = false,
             note = 'backend is write-only; retrieval is unavailable' }
  end

  local body, err = self._backend.read(path)
  if not body then
    return { records = {}, corrupt = {}, path = path, complete = false,
             note = 'read failed: ' .. tostring(err) }
  end

  local records, corrupt = self._deps.decode_lines(body)
  local complete = #corrupt == 0

  --[[
    Note the explicit `if`. `complete and nil or string.format(...)` would ALWAYS
    yield the string, because Lua's `and` cannot produce nil -- so every retrieval
    would have claimed to be incomplete. That bug shipped once and the tests caught
    it; the shape below is deliberate, not verbose for its own sake.
  ]]
  local note
  if not complete then
    note = string.format(
      '%d line(s) could not be parsed; this retrieval is incomplete', #corrupt)
  end

  return {
    records  = records,
    corrupt  = corrupt,
    path     = path,
    complete = complete,
    note     = note,
  }
end

--- Current integrity digest for a path, as a hex string, or nil if nothing was written.
function Store:digest(path)
  local d = self._digests[path]
  if not d then return nil end
  return string.format('%016x', d & 0xFFFFFFFFFFFFFFFF)
end

--[[
  Verify a file against a previously recorded digest.

  @return ok boolean, detail string
  See the note on the digest above: this detects corruption, not tampering.
]]
function Store:verify(kind, category, expected_hex)
  local path = self:path_for(kind, category)
  if type(self._backend.read) ~= 'function' then
    return false, 'backend is write-only; cannot verify'
  end
  local body, err = self._backend.read(path)
  if not body then return false, 'read failed: ' .. tostring(err) end

  local h = FNV_OFFSET
  local lines_n = 0
  for line in (body .. '\n'):gmatch('([^\n]*)\n') do
    if line ~= '' then
      h = fnv1a(h, line)
      lines_n = lines_n + 1
    end
  end
  local actual = string.format('%016x', h & 0xFFFFFFFFFFFFFFFF)
  if expected_hex == nil then
    return true, string.format('digest %s over %d line(s); no expected value supplied',
      actual, lines_n)
  end
  if actual == expected_hex then
    return true, string.format('digest matches (%s, %d line(s))', actual, lines_n)
  end
  return false, string.format(
    'digest mismatch: expected %s, computed %s over %d line(s). '
    .. 'The file was modified, truncated, or written by another process.',
    tostring(expected_hex), actual, lines_n)
end

--[[
  Accounting. Surfaced in health output.

  `lost_n` is the headline number: any non-zero value means the evidence store is
  not a complete record of what happened, and every consumer must say so.
]]
function Store:stats()
  local c = self._counts
  local by_kind = {}
  for k, v in pairs(c.by_kind) do by_kind[k] = v end
  local paths = {}
  for p in pairs(self._digests) do paths[#paths + 1] = p end
  table.sort(paths)
  return {
    written_n         = c.written_n,
    encode_failed_n   = c.encode_failed_n,
    backend_failed_n  = c.backend_failed_n,
    lost_n            = c.encode_failed_n + c.backend_failed_n,
    by_kind           = by_kind,
    files_n           = #paths,
    paths             = paths,
    failures          = self._failures,
    failures_truncated = #self._failures >= MAX_TRACKED_FAILURES,
  }
end

--- Is this store a complete record of everything it was asked to persist?
function Store:is_complete()
  local s = self:stats()
  if s.lost_n == 0 then return true, nil end
  return false, string.format(
    '%d record(s) were not persisted (%d encode, %d backend). '
    .. 'Any analysis over this store is working from an incomplete record.',
    s.lost_n, s.encode_failed_n, s.backend_failed_n)
end

--[[
  DUAL EXPORT -- see docs/ARCHITECTURE.md §3.2 "Module loading".
]]
SecLab = SecLab or {}
SecLab.evidence = M

return M

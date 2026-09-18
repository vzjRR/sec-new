--[[
  security-forensics / logic / timeline.lua

  PURE LUA. Assembles an ordered, gap-aware timeline from telemetry records.

  ---------------------------------------------------------------------------
  THE POINT OF THIS MODULE IS THE GAPS.

  The telemetry ring buffer drops the oldest record when it overflows and counts the
  drops (security-telemetry/logic/buffer.lua). Records also carry a per-process `seq`
  that increments by exactly one.

  That means a missing `seq` is DETECTABLE. And it must be surfaced, because an
  investigator reading a timeline with a silent hole in it would read continuity that
  never existed -- concluding "nothing happened between these two events" when in fact
  the record of what happened was discarded.

  A silent gap in evidence is worse than no evidence. So a gap becomes a first-class
  entry in the timeline, not a footnote.
  ---------------------------------------------------------------------------
]]

local M = {}

--[[
  Order records deterministically.

  Sort key is (mono, seq). `mono` is the monotonic clock -- never `ts`, because wall
  clock can step backwards and would reorder a timeline (docs/TELEMETRY_SCHEMA.md §1).
  `seq` breaks ties, since two records can share a millisecond.
]]
local function compare(a, b)
  local am, bm = a.mono or 0, b.mono or 0
  if am ~= bm then return am < bm end
  return (a.seq or 0) < (b.seq or 0)
end

--- Sort a copy; never mutate the caller's list.
function M.order(records)
  local out = {}
  for i, r in ipairs(records or {}) do out[i] = r end
  table.sort(out, compare)
  return out
end

--[[
  Build a timeline.

  @param records table   telemetry records (any order)
  @param opts    table   { correlation_id, player_key, dropped_n }
  @return timeline table {
            entries = { {kind='record'|'gap', ...} },
            stats   = { records_n, gaps_n, missing_n, span_ms, ... },
          }

  `opts.dropped_n` is the buffer's own drop count. It is reported alongside the
  seq-derived gaps because the two measure different things: seq gaps show records
  missing from THIS set (dropped, or filtered out by a query), while dropped_n is what
  the buffer knows it discarded. They will not always agree, and that discrepancy is
  itself information.
]]
function M.build(records, opts)
  opts = opts or {}
  local ordered = M.order(records)

  -- Optional filtering, applied before gap analysis so that a filtered-out record is
  -- not misreported as a dropped one.
  if opts.correlation_id or opts.player_key then
    local kept = {}
    for _, r in ipairs(ordered) do
      local ok = true
      if opts.correlation_id and r.correlation_id ~= opts.correlation_id then ok = false end
      if opts.player_key and r.player_key ~= opts.player_key then ok = false end
      if ok then kept[#kept + 1] = r end
    end
    ordered = kept
  end

  local entries = {}
  local missing_total, gaps_n = 0, 0
  local categories, trust_counts = {}, {}
  local claimed_n, observed_n = 0, 0

  local prev = nil
  for _, r in ipairs(ordered) do
    --[[
      Gap detection. Only meaningful when BOTH records are unfiltered neighbours from
      the same process, so it is skipped entirely when a filter was applied -- a
      filtered timeline legitimately has non-contiguous seq values, and reporting those
      as lost evidence would be a false alarm about our own data.
    ]]
    if prev and not (opts.correlation_id or opts.player_key) then
      local ps, cs = prev.seq, r.seq
      if type(ps) == 'number' and type(cs) == 'number' and cs > ps + 1 then
        local n = cs - ps - 1
        missing_total = missing_total + n
        gaps_n = gaps_n + 1
        entries[#entries + 1] = {
          kind        = 'gap',
          after_seq   = ps,
          before_seq  = cs,
          missing_n   = n,
          from_mono   = prev.mono,
          to_mono     = r.mono,
          duration_ms = (type(r.mono) == 'number' and type(prev.mono) == 'number')
                        and (r.mono - prev.mono) or nil,
          note        = string.format(
            '%d record(s) missing from this timeline. Evidence was discarded or '
            .. 'filtered; do not read continuity across this gap.', n),
        }
      end
    end

    entries[#entries + 1] = { kind = 'record', record = r }

    local cat = r.category or 'unknown'
    categories[cat] = (categories[cat] or 0) + 1
    local tr = r.trust or 'unknown'
    trust_counts[tr] = (trust_counts[tr] or 0) + 1
    if tr == 'claimed' then claimed_n = claimed_n + 1 end
    if tr == 'observed' or tr == 'framework' then observed_n = observed_n + 1 end

    prev = r
  end

  local first, last = ordered[1], ordered[#ordered]
  local span_ms = nil
  if first and last and type(first.mono) == 'number' and type(last.mono) == 'number' then
    span_ms = last.mono - first.mono
  end

  return {
    entries = entries,
    stats = {
      records_n      = #ordered,
      gaps_n         = gaps_n,
      missing_n      = missing_total,
      buffer_dropped_n = opts.dropped_n,
      span_ms        = span_ms,
      first_mono     = first and first.mono or nil,
      last_mono      = last and last.mono or nil,
      categories     = categories,
      trust          = trust_counts,
      claimed_n      = claimed_n,
      observed_n     = observed_n,
      filtered       = (opts.correlation_id ~= nil or opts.player_key ~= nil),
    },
  }
end

--[[
  Is this timeline complete enough to reason about?

  Returns ok, reason. A detector or analyst should treat `false` as "insufficient
  evidence", NOT as "nothing happened". The distinction is the whole reason gaps are
  tracked.
]]
function M.is_complete(timeline)
  local s = (timeline or {}).stats or {}
  if (s.gaps_n or 0) > 0 then
    return false, string.format(
      '%d gap(s) totalling %d missing record(s): insufficient evidence, not absence of evidence',
      s.gaps_n, s.missing_n or 0)
  end
  if (s.buffer_dropped_n or 0) > 0 then
    return false, string.format(
      'the telemetry buffer discarded %d record(s) during this period',
      s.buffer_dropped_n)
  end
  return true, nil
end

--[[
  Trust summary for an investigator.
  Answers at a glance: how much of this story did the attacker control?
]]
function M.trust_summary(timeline)
  local s = (timeline or {}).stats or {}
  local claimed, observed = s.claimed_n or 0, s.observed_n or 0
  local total = claimed + observed
  if total == 0 then
    return { claimed_n = 0, observed_n = 0, claimed_pct = nil,
             note = 'no trust-labelled records in this timeline' }
  end
  local pct = (claimed / total) * 100.0
  local note
  if claimed == 0 then
    note = 'entirely server-observed'
  elseif observed == 0 then
    note = 'entirely client-claimed: this timeline alone cannot support a '
        .. 'high-confidence conclusion'
  else
    note = string.format('%.0f%% of trust-labelled records are client claims', pct)
  end
  return { claimed_n = claimed, observed_n = observed, claimed_pct = pct, note = note }
end


--[[
  DUAL EXPORT -- see docs/ARCHITECTURE.md §3.2 "Module loading".

  FiveM has no documented `require` for resource scripts: every file listed in
  `server_scripts` is loaded as a plain chunk into one shared Lua state, and the
  chunk's return value is DISCARDED. So returning the table is not enough to make
  this module reachable inside FXServer.

  Vanilla Lua 5.4 (the CI tier) is the opposite: it uses the return value and has
  no shared namespace.

  Publishing to a single resource-scoped global satisfies both without an
  environment check. Each resource gets its own Lua state, so `SecLab` does not
  leak between resources.
]]
SecLab = SecLab or {}
SecLab.timeline = M

return M

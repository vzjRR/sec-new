--[[
  security-lab-exp / logic / recorder.lua

  PURE LUA. Accumulates experiment results and renders them.

  An experiment harness is a MEASURING INSTRUMENT, and a bad instrument is worse than
  none: it produces numbers that look authoritative and are wrong. So this module is
  strict about three things:

    1. Every result declares its EXP id and whether it CONCLUDED or was inconclusive.
       "Inconclusive" is a first-class outcome -- an experiment that could not run
       must never read as one that found nothing.
    2. Sample counts travel with every measurement. A latency figure from 3 samples
       is not the same claim as one from 3000, and the reader must see which it is.
    3. Findings are tagged FACT / OBSERVATION / HYPOTHESIS per CLAUDE.md §5, and the
       recorder refuses a finding with no tag.
]]

local M = {}

M.CONCLUDED    = 'concluded'
M.INCONCLUSIVE = 'inconclusive'
M.FAILED       = 'failed'
M.SKIPPED      = 'skipped'

M.TAGS = { FACT = true, OBSERVATION = true, HYPOTHESIS = true }

local Recorder = {}
Recorder.__index = Recorder

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    _results = {},
    _order   = {},
    _meta    = {
      started_at = opts.started_at,
      build      = opts.build,
      mode       = opts.mode,
    },
  }, Recorder)
end

--[[
  Record an experiment outcome.

  spec = {
    id       = 'EXP-009',
    question = 'Is require available to resource scripts?',
    status   = M.CONCLUDED | M.INCONCLUSIVE | M.FAILED | M.SKIPPED,
    tag      = 'FACT' | 'OBSERVATION' | 'HYPOTHESIS',   -- required when concluded
    finding  = 'one sentence',
    detail   = { ... },        -- arbitrary structured evidence
    samples_n = 120,           -- required when a measurement is reported
    reason   = '...',          -- required when NOT concluded
  }
]]
function Recorder:record(spec)
  if type(spec) ~= 'table' then return false, 'spec must be a table' end
  if type(spec.id) ~= 'string' or spec.id == '' then return false, 'id required' end

  local status = spec.status or M.INCONCLUSIVE
  if status ~= M.CONCLUDED and status ~= M.INCONCLUSIVE
     and status ~= M.FAILED and status ~= M.SKIPPED then
    return false, 'unknown status ' .. tostring(status)
  end

  if status == M.CONCLUDED then
    if not M.TAGS[spec.tag or ''] then
      -- An untagged conclusion cannot be read against the evidence standard, and a
      -- reader would have to guess whether it is fact or speculation.
      return false, string.format(
        '%s concluded without a FACT/OBSERVATION/HYPOTHESIS tag', spec.id)
    end
    if type(spec.finding) ~= 'string' or #spec.finding < 10 then
      return false, string.format('%s concluded without a stated finding', spec.id)
    end
  else
    if type(spec.reason) ~= 'string' or #spec.reason < 5 then
      -- "It didn't work" is not a result. Why it didn't is.
      return false, string.format(
        '%s is %s but gives no reason', spec.id, status)
    end
  end

  local row = {
    id        = spec.id,
    question  = spec.question,
    status    = status,
    tag       = spec.tag,
    finding   = spec.finding,
    reason    = spec.reason,
    detail    = spec.detail or {},
    samples_n = spec.samples_n,
    blocks    = spec.blocks,
  }

  if self._results[spec.id] == nil then self._order[#self._order + 1] = spec.id end
  self._results[spec.id] = row
  return true, nil
end

function Recorder:get(id) return self._results[id] end

function Recorder:all()
  local out = {}
  for _, id in ipairs(self._order) do out[#out + 1] = self._results[id] end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function Recorder:summary()
  local s = { total = 0, concluded = 0, inconclusive = 0, failed = 0, skipped = 0,
              unblocked = {}, still_blocked = {} }
  for _, r in ipairs(self:all()) do
    s.total = s.total + 1
    s[r.status] = (s[r.status] or 0) + 1
    if r.status == M.CONCLUDED then
      if r.blocks then s.unblocked[#s.unblocked + 1] = r.id end
    elseif r.blocks then
      s.still_blocked[#s.still_blocked + 1] = r.id
    end
  end
  return s
end

--- A serialisable bundle for writing to disk and handing back for analysis.
function Recorder:bundle()
  return { meta = self._meta, results = self:all(), summary = self:summary() }
end

--- Render for a server console.
function Recorder:render()
  local L = {}
  local function line(fmt, ...)
    L[#L + 1] = select('#', ...) > 0 and string.format(fmt, ...) or fmt
  end

  line('=========================================================')
  line('FiveM Security Lab -- experiment results')
  line('  mode  %s', tostring(self._meta.mode))
  line('  build %s', tostring(self._meta.build))
  line('=========================================================')

  for _, r in ipairs(self:all()) do
    line('')
    line('%s  [%s]%s', r.id, string.upper(r.status),
      r.tag and ('  ' .. r.tag) or '')
    if r.question then line('  Q: %s', r.question) end
    if r.status == M.CONCLUDED then
      line('  > %s', tostring(r.finding))
      if r.samples_n then line('    (%d sample(s))', r.samples_n) end
    else
      line('  ! %s', tostring(r.reason))
    end
    for k, v in pairs(r.detail or {}) do
      if type(v) ~= 'table' then
        line('    %-24s %s', tostring(k), tostring(v))
      end
    end
  end

  local s = self:summary()
  line('')
  line('---------------------------------------------------------')
  line('%d experiment(s): %d concluded, %d inconclusive, %d failed, %d skipped',
    s.total, s.concluded, s.inconclusive, s.failed, s.skipped)
  if #s.unblocked > 0 then
    line('unblocked: %s', table.concat(s.unblocked, ', '))
  end
  if #s.still_blocked > 0 then
    line('STILL BLOCKED: %s', table.concat(s.still_blocked, ', '))
  end
  line('---------------------------------------------------------')
  return table.concat(L, '\n')
end

-- ---------------------------------------------------------------------------
-- Statistics for sampled experiments.
-- ---------------------------------------------------------------------------

--[[
  Summarise a numeric sample set.

  Returns nil when there are too few samples to say anything, rather than returning
  a mean of one value -- which would look like a measurement and be noise. The
  minimum is deliberately explicit so the caller must think about it.
]]
function M.stats(values, min_samples)
  min_samples = min_samples or 5
  if type(values) ~= 'table' or #values < min_samples then
    return nil, string.format('need at least %d samples, have %d',
      min_samples, type(values) == 'table' and #values or 0)
  end

  local sorted = {}
  for i, v in ipairs(values) do sorted[i] = v end
  table.sort(sorted)

  local n = #sorted
  local sum = 0
  for _, v in ipairs(sorted) do sum = sum + v end
  local mean = sum / n

  local var = 0
  for _, v in ipairs(sorted) do var = var + (v - mean) ^ 2 end
  var = n > 1 and (var / (n - 1)) or 0

  local function pct(p)
    local idx = math.max(1, math.min(n, math.ceil(p / 100 * n)))
    return sorted[idx]
  end

  return {
    n = n, min = sorted[1], max = sorted[n], mean = mean,
    stddev = math.sqrt(var),
    p50 = pct(50), p90 = pct(90), p99 = pct(99),
  }
end

--[[
  DUAL EXPORT -- see docs/ARCHITECTURE.md §3.2 "Module loading".
]]
SecLab = SecLab or {}
SecLab.recorder = M

return M

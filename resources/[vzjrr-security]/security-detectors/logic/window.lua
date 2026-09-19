--[[
  security-detectors / logic / window.lua

  PURE LUA. A bounded sliding-window event counter, keyed by an arbitrary string.

  Rate detectors need to answer "how many X in the last N ms for this player". Doing
  that naively -- a growing list per player -- is how a security resource becomes the
  thing that exhausts a busy server's memory, which charter §15 forbids and which
  would be worst during exactly the incident the detector exists to catch.

  So this is bounded on BOTH axes:

    * events per key  -- a burst cannot grow one key without limit
    * number of keys  -- a churn of player/type combinations cannot grow the table

  And, as everywhere else in this project, **eviction is counted**. A count computed
  after events were silently dropped would understate a rate, which for a rate
  detector means silently failing to detect. The detector reads `evicted_events_n`
  and must degrade its confidence rather than report a number it cannot stand behind.
]]

local M = {}

local Window = {}
Window.__index = Window

--- @param opts { window_ms, max_keys, max_events_per_key }
function M.new(opts)
  opts = opts or {}
  local window_ms = opts.window_ms or 60000
  assert(type(window_ms) == 'number' and window_ms > 0,
    'window: window_ms must be a positive number')
  return setmetatable({
    _window_ms = window_ms,
    _max_keys  = opts.max_keys or 1024,
    _max_per   = opts.max_events_per_key or 512,
    _keys      = {},   -- [key] = { times = {…}, head, tail, n, last_mono }
    _keys_n    = 0,
    _evicted_events_n = 0,
    _evicted_keys_n   = 0,
  }, Window)
end

function Window:window_ms() return self._window_ms end

local function new_entry(mono)
  return { times = {}, n = 0, last_mono = mono }
end

--[[
  Drop the least-recently-touched key.

  LRU rather than random or first-seen: the key we are least likely to need is the one
  nothing has touched. A player who stopped generating events is the right thing to
  forget first.
]]
function Window:_evict_lru()
  local oldest_key, oldest_mono
  for k, e in pairs(self._keys) do
    if not oldest_mono or e.last_mono < oldest_mono then
      oldest_key, oldest_mono = k, e.last_mono
    end
  end
  if oldest_key then
    self._evicted_events_n = self._evicted_events_n + self._keys[oldest_key].n
    self._keys[oldest_key] = nil
    self._keys_n = self._keys_n - 1
    self._evicted_keys_n = self._evicted_keys_n + 1
  end
end

--- Drop entries older than the window from one key.
local function expire(entry, now, window_ms)
  local cutoff = now - window_ms
  local kept = {}
  for _, t in ipairs(entry.times) do
    if t >= cutoff then kept[#kept + 1] = t end
  end
  entry.times = kept
  entry.n = #kept
end

--[[
  Record an event.
  @return count_in_window number
]]
function Window:add(key, mono)
  if type(key) ~= 'string' or type(mono) ~= 'number' then return 0 end

  local entry = self._keys[key]
  if not entry then
    if self._keys_n >= self._max_keys then self:_evict_lru() end
    entry = new_entry(mono)
    self._keys[key] = entry
    self._keys_n = self._keys_n + 1
  end

  expire(entry, mono, self._window_ms)

  if entry.n >= self._max_per then
    --[[
      The key is saturated. Drop the OLDEST in-window event to make room, so the
      count reflects the most recent activity, and count the loss. Refusing the new
      event instead would make a sustained burst look like it had stopped.
    ]]
    table.remove(entry.times, 1)
    entry.n = entry.n - 1
    self._evicted_events_n = self._evicted_events_n + 1
  end

  entry.times[#entry.times + 1] = mono
  entry.n = entry.n + 1
  entry.last_mono = mono
  return entry.n
end

--- Current count for a key, expiring anything outside the window.
function Window:count(key, mono)
  local entry = self._keys[key]
  if not entry then return 0 end
  if type(mono) == 'number' then expire(entry, mono, self._window_ms) end
  return entry.n
end

--- Monotonic time of the most recent event for a key, or nil.
function Window:last(key)
  local entry = self._keys[key]
  return entry and entry.last_mono or nil
end

--[[
  Drop keys whose most recent event is older than the window.
  Called on a timer by the adapter so an idle server's table shrinks rather than
  holding every key that has ever been seen.
]]
function Window:prune(mono)
  if type(mono) ~= 'number' then return 0 end
  local cutoff = mono - self._window_ms
  local removed = 0
  for k, e in pairs(self._keys) do
    if e.last_mono < cutoff then
      self._keys[k] = nil
      self._keys_n = self._keys_n - 1
      removed = removed + 1
    end
  end
  return removed
end

--- Forget one key entirely, e.g. when a player disconnects.
function Window:forget(key)
  if self._keys[key] then
    self._keys[key] = nil
    self._keys_n = self._keys_n - 1
    return true
  end
  return false
end

--[[
  Has anything been lost?

  A detector must consult this: a count taken after eviction is a FLOOR, not a
  measurement, and reporting a rate from it as if it were exact would understate the
  real rate -- a silent failure to detect.
]]
function Window:lossy()
  return self._evicted_events_n > 0 or self._evicted_keys_n > 0
end

function Window:stats()
  return {
    keys_n            = self._keys_n,
    window_ms         = self._window_ms,
    max_keys          = self._max_keys,
    max_events_per_key = self._max_per,
    evicted_events_n  = self._evicted_events_n,
    evicted_keys_n    = self._evicted_keys_n,
  }
end

--[[
  DUAL EXPORT -- see docs/ARCHITECTURE.md §3.2 "Module loading".
]]
SecLab = SecLab or {}
SecLab.window = M

return M

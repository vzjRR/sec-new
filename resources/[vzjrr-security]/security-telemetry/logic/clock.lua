--[[
  security-telemetry / logic / clock.lua

  PURE LUA. Time sources are INJECTED, never read directly.

  Why: docs/TELEMETRY_SCHEMA.md §1 requires that every timing measurement be derived
  from a monotonic source. A wall clock that steps backwards (NTP correction, DST,
  operator action) would manufacture negative or impossible intervals -- and an
  impossible interval is indistinguishable from the thing we are trying to detect.
  A false accusation caused by an NTP step would be the worst possible failure mode,
  so the clock is a first-class, testable component rather than a call to os.time().

  Injection also makes every time-dependent test deterministic.
]]

local M = {}

local Clock = {}
Clock.__index = Clock

--- Create a clock.
-- @param wall_fn   function -> integer ms since epoch   (adapter passes os.time()*1000)
-- @param mono_fn   function -> integer ms, monotonic     (adapter passes GetGameTimer())
function M.new(wall_fn, mono_fn)
  assert(type(wall_fn) == 'function', 'clock: wall_fn must be a function')
  assert(type(mono_fn) == 'function', 'clock: mono_fn must be a function')
  return setmetatable({
    _wall        = wall_fn,
    _mono        = mono_fn,
    _last_mono   = nil,
    _regressions = 0,
  }, Clock)
end

function Clock:wall() return self._wall() end

--- Monotonic milliseconds, defended against a non-monotonic source.
-- GetGameTimer() is expected to be monotonic, but this is asserted rather than
-- assumed: if the source ever regresses we clamp and count it, so the anomaly
-- surfaces as a system health signal instead of as a player's "impossible" timing.
function Clock:mono()
  local m = self._mono()
  if self._last_mono and m < self._last_mono then
    self._regressions = self._regressions + 1
    m = self._last_mono
  end
  self._last_mono = m
  return m
end

--- Number of times the monotonic source went backwards. Reported in health output.
function Clock:regressions() return self._regressions end

--[[
  Interval between two monotonic readings.
  Returns nil when the interval is not trustworthy, which the caller MUST treat as
  "no measurement" rather than as zero. Returning 0 here would let a detector read a
  missing interval as an instantaneous one -- precisely the arithmetic that produces
  a bogus "impossible reaction time".
]]
function Clock:interval_ms(from_mono, to_mono)
  if type(from_mono) ~= 'number' or type(to_mono) ~= 'number' then return nil end
  local d = to_mono - from_mono
  if d < 0 then return nil end
  return d
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
SecLab.clock = M

return M

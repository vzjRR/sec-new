--[[
  security-core / lib / logger.lua

  PURE LUA. Structured logging with an INJECTED writer, so logging is testable and
  the same logger works in FXServer (print / PrintStructuredTrace) and in CI (a table).

  Structured, not printf: charter §Telemetry requires queryable output, and a
  security log that can only be read by a human grep is not evidence.
]]

local M = {}

M.LEVELS = { debug = 10, info = 20, warn = 30, error = 40 }

local ORDER = { 'debug', 'info', 'warn', 'error' }

local Logger = {}
Logger.__index = Logger

--- @param writer function(entry table)  receives each structured entry
-- @param opts { level = 'info', component = 'security-core', clock = <logic.clock> }
function M.new(writer, opts)
  assert(type(writer) == 'function', 'logger: writer must be a function')
  opts = opts or {}
  local lvl = M.LEVELS[opts.level or 'info']
  assert(lvl, 'logger: unknown level ' .. tostring(opts.level))
  return setmetatable({
    _writer    = writer,
    _min       = lvl,
    _component = opts.component or 'security',
    _clock     = opts.clock,
    _counts    = { debug = 0, info = 0, warn = 0, error = 0 },
  }, Logger)
end

function Logger:set_level(name)
  local lvl = M.LEVELS[name]
  if not lvl then return false end
  self._min = lvl
  return true
end

function Logger:counts()
  local out = {}
  for k, v in pairs(self._counts) do out[k] = v end
  return out
end

local function emit(self, level, msg, fields)
  if M.LEVELS[level] < self._min then return false end
  self._counts[level] = self._counts[level] + 1
  local entry = {
    level     = level,
    component = self._component,
    msg       = msg,
    ts        = self._clock and self._clock:wall() or nil,
    mono      = self._clock and self._clock:mono() or nil,
  }
  if fields then
    for k, v in pairs(fields) do
      -- Never let a field overwrite the envelope; a caller-supplied `level` must
      -- not be able to disguise an error as debug output.
      if entry[k] == nil and k ~= 'level' and k ~= 'component' then entry[k] = v end
    end
  end
  self._writer(entry)
  return true
end

for _, name in ipairs(ORDER) do
  Logger[name] = function(self, msg, fields) return emit(self, name, msg, fields) end
end

--- Render an entry as a single human-readable line (console fallback).
function M.format(entry)
  local parts = {}
  for k, v in pairs(entry) do
    if k ~= 'level' and k ~= 'msg' and k ~= 'component' then
      parts[#parts + 1] = tostring(k) .. '=' .. tostring(v)
    end
  end
  table.sort(parts)
  local tail = #parts > 0 and ('  ' .. table.concat(parts, ' ')) or ''
  return string.format('[%s] %s: %s%s',
    entry.component or '?', string.upper(entry.level or '?'), tostring(entry.msg), tail)
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
SecLab.logger = M

return M

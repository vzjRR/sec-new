--[[
  security-telemetry / sinks / memory.lua
  In-memory sink. Used by tests and by LAB inspection. Bounded, like every sink.
]]
local M = {}

function M.new(limit)
  local records, dropped = {}, 0
  limit = limit or 10000
  return {
    name = 'memory',
    write = function(rec)
      if #records >= limit then
        table.remove(records, 1)
        dropped = dropped + 1
      end
      records[#records + 1] = rec
      return true
    end,
    flush = function() return true end,
    all   = function() return records end,
    stats = function() return { size_n = #records, dropped_n = dropped } end,
  }
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
SecLab.sink_memory = M

return M

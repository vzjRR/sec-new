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

return M

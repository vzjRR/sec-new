--[[
  security-telemetry / logic / buffer.lua

  PURE LUA. A bounded ring buffer between the hot path and the sink.

  WHY BOUNDED, AND WHY IT DROPS THE OLDEST:

  charter §15 forbids letting security collection damage the server. An unbounded
  queue turns a telemetry spike -- which is exactly what a mass-abuse incident looks
  like -- into server memory exhaustion. The anti-cheat must not be the thing that
  takes the server down during an attack.

  When full it overwrites the OLDEST record. That is the right trade for a live
  pipeline: recent events carry the current incident. Crucially, every drop is
  COUNTED and the count is reported, so an investigator is never shown a gap in a
  timeline without also being told the gap exists. A silent gap in evidence is worse
  than no evidence.
]]

local M = {}

local Buffer = {}
Buffer.__index = Buffer

function M.new(capacity)
  capacity = capacity or 2048
  assert(type(capacity) == 'number' and capacity >= 1 and capacity == math.floor(capacity),
    'buffer: capacity must be a positive integer')
  return setmetatable({
    _cap = capacity, _items = {}, _head = 0, _tail = 0, _n = 0,
    _pushed = 0, _dropped = 0,
  }, Buffer)
end

function Buffer:capacity() return self._cap end
function Buffer:len() return self._n end
function Buffer:is_full() return self._n == self._cap end
function Buffer:is_empty() return self._n == 0 end

--- Total records ever accepted.
function Buffer:pushed() return self._pushed end
--- Total records overwritten before they could be flushed. Reported in health.
function Buffer:dropped() return self._dropped end

--- Push a record. Returns true, or false when it evicted an older record.
function Buffer:push(item)
  if item == nil then return false end
  self._pushed = self._pushed + 1
  self._head = (self._head % self._cap) + 1
  if self._n == self._cap then
    -- Full: advance the tail, losing the oldest.
    self._tail = (self._tail % self._cap) + 1
    self._dropped = self._dropped + 1
    self._items[self._head] = item
    return false
  end
  if self._n == 0 then self._tail = self._head end
  self._items[self._head] = item
  self._n = self._n + 1
  return true
end

--- Remove and return up to `max` oldest records, in order.
function Buffer:drain(max)
  max = max or self._n
  local out = {}
  while self._n > 0 and #out < max do
    out[#out + 1] = self._items[self._tail]
    self._items[self._tail] = nil
    self._n = self._n - 1
    if self._n == 0 then
      self._tail, self._head = 0, 0
    else
      self._tail = (self._tail % self._cap) + 1
    end
  end
  return out
end

--- Oldest record without removing it.
function Buffer:peek()
  if self._n == 0 then return nil end
  return self._items[self._tail]
end

function Buffer:stats()
  return {
    capacity_n = self._cap,
    size_n     = self._n,
    pushed_n   = self._pushed,
    dropped_n  = self._dropped,
  }
end

return M

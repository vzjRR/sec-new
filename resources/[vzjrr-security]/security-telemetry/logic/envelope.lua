--[[
  security-telemetry / logic / envelope.lua

  PURE LUA. Builds the TelemetryRecord envelope (docs/TELEMETRY_SCHEMA.md §1).

  All normalizers go through this, so envelope construction exists in exactly one
  place and a new adapter cannot accidentally omit `trust` or `mono`.
]]

local schema = require('logic.schema')

local M = {}

local Builder = {}
Builder.__index = Builder

--- @param clock  a logic.clock instance
-- @param opts   { mode = 'LAB'|'PRODUCTION' }
function M.new(clock, opts)
  assert(clock, 'envelope: clock required')
  opts = opts or {}
  return setmetatable({
    _clock = clock,
    _seq   = 0,
    _mode  = opts.mode or 'PRODUCTION',
  }, Builder)
end

function Builder:next_seq()
  self._seq = self._seq + 1
  return self._seq
end

--[[
  Build a record.

  spec = {
    player_key   = 'QB:ABC' | 'SRC:12' | 'SYSTEM',
    src          = 12,                  -- optional
    category     = 'combat',
    event        = 'weapon_damage',
    source       = 'event:weaponDamageEvent',
    trust        = 'claimed',
    measurements = { ... },              -- optional
    context      = { ... },              -- optional
    correlation_id = 'c_x',              -- optional
  }
]]
function Builder:build(spec)
  assert(type(spec) == 'table', 'envelope: spec must be a table')

  local ctx = {}
  if spec.context then
    for k, v in pairs(spec.context) do ctx[k] = v end
  end
  -- Mode is stamped on every record so a fixture can never be mistaken for
  -- production data, or vice versa, once it is out of its directory.
  ctx.mode = ctx.mode or self._mode

  return {
    schema_version = schema.SCHEMA_VERSION,
    ts             = self._clock:wall(),
    mono           = self._clock:mono(),
    seq            = self:next_seq(),
    player_key     = spec.player_key,
    src            = spec.src,
    category       = spec.category,
    event          = spec.event,
    source         = spec.source,
    measurements   = spec.measurements or {},
    context        = ctx,
    correlation_id = spec.correlation_id,
    trust          = spec.trust,
  }
end

return M

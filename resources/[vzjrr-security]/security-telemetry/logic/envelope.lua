--[[
  security-telemetry / logic / envelope.lua

  PURE LUA. Builds the TelemetryRecord envelope (docs/TELEMETRY_SCHEMA.md §1).

  All normalizers go through this, so envelope construction exists in exactly one
  place and a new adapter cannot accidentally omit `trust` or `mono`.
]]

--[[
  Resolve a sibling module in either environment (see the dual-export note at the
  foot of every pure module). Inside FXServer the sibling is already published on
  the resource-scoped `SecLab` table by an earlier `server_scripts` entry; under
  vanilla Lua in CI it is loaded with `require`.
]]
local function sec_require(key, path)
  if SecLab and SecLab[key] then return SecLab[key] end
  return require(path)
end

local schema = sec_require('schema', 'logic.schema')

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
SecLab.envelope = M

return M

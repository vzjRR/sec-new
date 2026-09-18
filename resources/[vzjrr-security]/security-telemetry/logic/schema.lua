--[[
  security-telemetry / logic / schema.lua

  PURE LUA. No natives, no CfxLua extensions (no backtick hashes, no vector3).
  Unit-tested in CI by tests/unit/test_schema.lua.

  Owns the TelemetryRecord contract described in docs/TELEMETRY_SCHEMA.md.
  Every record the platform emits passes through validate() in LAB mode and in CI,
  so an adapter cannot quietly invent its own shape.
]]

local M = {}

M.SCHEMA_VERSION = 1

-- docs/TELEMETRY_SCHEMA.md §3
M.CATEGORIES = {
  combat       = true,
  aim          = true,
  movement     = true,
  event        = true,
  entity       = true,
  economy      = true,
  player_state = true,
  network      = true,
  system       = true,
}

-- docs/TELEMETRY_SCHEMA.md §6. Provenance travels with the data, not in a comment.
M.TRUST = {
  observed  = true, -- server computed it from its own state
  claimed   = true, -- attacker-influenced payload the server merely routed
  derived   = true, -- we computed it from other records
  framework = true, -- QBCore's server-side view
}

--[[
  Unit suffixes for measurement keys. docs/TELEMETRY_SCHEMA.md §4 requires every
  measurement to name its unit, because an unlabelled number invites the exact
  class of bug that turns into a false accusation: comparing metres to feet,
  or seconds to milliseconds, and calling the result impossible.
]]
M.UNIT_SUFFIXES = {
  ms    = true, -- milliseconds
  s     = true, -- seconds
  m     = true, -- metres
  mps   = true, -- metres per second
  mps2  = true, -- metres per second squared
  deg   = true, -- degrees
  pct   = true, -- percent, 0-100
  n     = true, -- dimensionless count or magnitude
  hz    = true, -- per second
  bytes = true,
}

-- Keys that must never appear anywhere in a record. docs/QBCORE_INTEGRATION.md §2.
-- Enforced rather than documented, because PII leaks happen by accident.
M.FORBIDDEN_KEYS = {
  firstname   = true,
  lastname    = true,
  birthdate   = true,
  phone       = true,
  account     = true,
  license     = true,
  steam       = true,
  discord     = true,
  ip          = true,
  endpoint    = true,
  xbl         = true,
  live        = true,
  fivem       = true,
  name        = true, -- player display names are user-supplied and identifying
}

local ENVELOPE_FIELDS = {
  schema_version = 'number',
  ts             = 'number',
  mono           = 'number',
  seq            = 'number',
  player_key     = 'string',
  category       = 'string',
  event          = 'string',
  source         = 'string',
  measurements   = 'table',
  context        = 'table',
  trust          = 'string',
}

local function is_integer(v)
  return type(v) == 'number' and v == math.floor(v) and v == v and v ~= math.huge and v ~= -math.huge
end

--- Split a measurement key into name and unit suffix.
-- @return name, unit  (unit is nil when the key has no `_suffix`)
function M.split_unit(key)
  local name, unit = key:match('^(.-)_([%a%d]+)$')
  if not name or name == '' then return key, nil end
  return name, unit
end

--- Validate a telemetry record against the schema.
-- @param rec table
-- @return ok boolean, errors table (list of strings; empty when ok)
function M.validate(rec)
  local errs = {}
  local function err(fmt, ...) errs[#errs + 1] = string.format(fmt, ...) end

  if type(rec) ~= 'table' then
    return false, { 'record is not a table' }
  end

  for field, want in pairs(ENVELOPE_FIELDS) do
    local got = type(rec[field])
    if got == 'nil' then
      err('missing envelope field %q', field)
    elseif got ~= want then
      err('envelope field %q: expected %s, got %s', field, want, got)
    end
  end

  if rec.schema_version ~= nil and rec.schema_version ~= M.SCHEMA_VERSION then
    err('schema_version %s is not supported (this build speaks %d)',
      tostring(rec.schema_version), M.SCHEMA_VERSION)
  end

  for _, f in ipairs({ 'ts', 'mono', 'seq' }) do
    if rec[f] ~= nil and not is_integer(rec[f]) then
      err('envelope field %q must be an integer millisecond/counter value', f)
    end
  end
  if is_integer(rec.mono) and rec.mono < 0 then
    err('mono must not be negative')
  end

  if type(rec.category) == 'string' and not M.CATEGORIES[rec.category] then
    err('unknown category %q', rec.category)
  end
  if type(rec.trust) == 'string' and not M.TRUST[rec.trust] then
    err('unknown trust level %q', rec.trust)
  end

  -- player_key must be a recognised, non-identifying form. docs/TELEMETRY_SCHEMA.md §2
  if type(rec.player_key) == 'string' then
    if not (rec.player_key:match('^QB:[%w_-]+$') or rec.player_key:match('^SRC:%d+$')
            or rec.player_key == 'SYSTEM') then
      err('player_key %q is not a recognised form (QB:<citizenid> | SRC:<n> | SYSTEM)',
        rec.player_key)
    end
  end

  if rec.src ~= nil and not is_integer(rec.src) then
    err('src must be an integer server id when present')
  end
  if rec.correlation_id ~= nil and type(rec.correlation_id) ~= 'string' then
    err('correlation_id must be a string when present')
  end

  -- measurements: numbers only, units mandatory. docs/TELEMETRY_SCHEMA.md §4
  if type(rec.measurements) == 'table' then
    for k, v in pairs(rec.measurements) do
      if type(k) ~= 'string' then
        err('measurement key must be a string, got %s', type(k))
      else
        if type(v) ~= 'number' then
          err('measurement %q must be a number, got %s (non-numeric data belongs in context)',
            k, type(v))
        elseif v ~= v then
          err('measurement %q is NaN', k)
        elseif v == math.huge or v == -math.huge then
          err('measurement %q is infinite', k)
        end
        local _, unit = M.split_unit(k)
        if not unit or not M.UNIT_SUFFIXES[unit] then
          err('measurement %q has no recognised unit suffix', k)
        end
      end
    end
  end

  -- context: qualifiers, not measurements
  if type(rec.context) == 'table' then
    for k, v in pairs(rec.context) do
      if type(k) ~= 'string' then
        err('context key must be a string, got %s', type(k))
      elseif type(v) == 'table' then
        err('context %q must be a scalar, not a table (keep records flat)', k)
      elseif type(v) == 'string' and #v > 128 then
        err('context %q string is %d chars; contexts are low-cardinality qualifiers', k, #v)
      end
    end
  end

  -- PII sweep across both bags and the envelope
  for _, bag in ipairs({ rec.measurements, rec.context, rec }) do
    if type(bag) == 'table' then
      for k in pairs(bag) do
        if type(k) == 'string' and M.FORBIDDEN_KEYS[k:lower()] then
          err('forbidden key %q: PII and identifiers must not enter telemetry', k)
        end
      end
    end
  end

  return #errs == 0, errs
end

--- Convenience for callers that want to fail loudly.
function M.assert_valid(rec)
  local ok, errs = M.validate(rec)
  if not ok then
    error('invalid telemetry record: ' .. table.concat(errs, '; '), 2)
  end
  return rec
end

return M

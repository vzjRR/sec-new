--[[
  security-core / lib / mode.lua

  PURE LUA. Resolves and freezes the LAB / PRODUCTION mode (docs/ARCHITECTURE.md §6).

  Fails CLOSED: anything unrecognised, empty or absent resolves to PRODUCTION.
  Rationale -- the dangerous direction is a lab capability (synthetic event injection,
  scenario simulators, raw payload capture) waking up on a live server. A typo in a
  ConVar must therefore cost lab features, never production safety. The charter is
  explicit about this: "Never accidentally ship a simulator as part of production
  protection."
]]

local M = {}

M.LAB        = 'LAB'
M.PRODUCTION = 'PRODUCTION'

-- Capabilities gated by mode. docs/ARCHITECTURE.md §6.
local CAPABILITIES = {
  verbose_telemetry     = { LAB = true, PRODUCTION = false },
  synthetic_events      = { LAB = true, PRODUCTION = false },
  scenario_simulators   = { LAB = true, PRODUCTION = false },
  experimental_detectors= { LAB = true, PRODUCTION = false },
  developer_commands    = { LAB = true, PRODUCTION = false },
  raw_payload_capture   = { LAB = true, PRODUCTION = false },
  core_telemetry        = { LAB = true, PRODUCTION = true  },
  detection             = { LAB = true, PRODUCTION = true  },
}

--- Resolve a raw ConVar string into a mode.
-- @return mode string, note string|nil  (note is set when input was not understood)
function M.resolve(raw)
  if type(raw) ~= 'string' then
    return M.PRODUCTION, 'security_mode was not a string; defaulted to PRODUCTION'
  end
  local v = raw:gsub('^%s+', ''):gsub('%s+$', ''):upper()
  if v == M.LAB then return M.LAB, nil end
  if v == M.PRODUCTION then return M.PRODUCTION, nil end
  if v == '' then
    return M.PRODUCTION, 'security_mode was empty; defaulted to PRODUCTION'
  end
  return M.PRODUCTION,
    string.format('security_mode %q is not recognised; defaulted to PRODUCTION', raw)
end

--- Is a named capability permitted in this mode?
-- An unknown capability is DENIED, so adding a lab feature without registering it
-- here cannot accidentally leave it enabled in production.
function M.allows(mode, capability)
  local row = CAPABILITIES[capability]
  if not row then return false end
  return row[mode] == true
end

function M.capabilities(mode)
  local out = {}
  for name, row in pairs(CAPABILITIES) do out[name] = row[mode] == true end
  return out
end

--- Guard for a lab-only entry point.
-- @return ok boolean, reason string|nil
function M.require_lab(mode, what)
  if mode == M.LAB then return true, nil end
  return false, string.format(
    '%s is LAB-only and was refused in %s mode', what or 'this operation', tostring(mode))
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
SecLab.mode = M

return M

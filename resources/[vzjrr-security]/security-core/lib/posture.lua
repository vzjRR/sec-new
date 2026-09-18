--[[
  security-core / lib / posture.lua

  PURE LUA. Audits the server's own ConVar posture against a hardened baseline.

  WHY THIS IS THE FIRST DETECTOR (docs/ENVIRONMENT_AUDIT.md §7.7, §10.2):

  Several FiveM security ConVars default to the permissive setting. On a default
  server, clients may write their own player state bag, create arbitrary entities, and
  request control of entities they do not own. A meaningful share of "cheating" on such
  a server is simply *permitted by configuration*.

  Detecting an abuse the server is configured to allow is strictly worse than
  disallowing it. So this runs first. It also has a property no behavioural detector
  can have: it makes findings about the SERVER, never accusations about a player, so
  its false-positive risk against players is exactly zero.

  Input is a plain table of ConVar values, read by the adapter via GetConvar*.
]]

local M = {}

M.CRITICAL, M.HIGH, M.MEDIUM, M.LOW, M.INFO = 'critical', 'high', 'medium', 'low', 'info'

local SEVERITY_RANK = {
  critical = 5, high = 4, medium = 3, low = 2, info = 1,
}

local function truthy(v)
  if type(v) == 'boolean' then return v end
  if type(v) ~= 'string' then return nil end
  local s = v:lower()
  if s == 'true' or s == '1' or s == 'yes' then return true end
  if s == 'false' or s == '0' or s == 'no' then return false end
  return nil
end

local function as_int(v)
  if type(v) == 'number' then return math.floor(v) end
  if type(v) ~= 'string' then return nil end
  return tonumber(v) and math.floor(tonumber(v)) or nil
end

--[[
  Each check states WHY, not just what, because a finding a server owner does not
  understand is a finding they will ignore or disable.

  `impact` explains the consequence in terms of what becomes possible.
  `remediation` is the exact line to put in server.cfg.
]]
local CHECKS = {
  {
    id = 'POSTURE-001', convar = 'onesync', severity = M.CRITICAL,
    evaluate = function(v)
      local s = tostring(v or ''):lower()
      if s == 'on' then return true end
      return false, string.format('onesync is %q', s == '' and '<unset>' or s)
    end,
    impact = 'Without onesync=on the server-side game events (weaponDamageEvent, '
          .. 'explosionEvent, entity events) and the server camera natives do not '
          .. 'exist. This platform cannot observe combat, aim or entities at all.',
    remediation = 'set onesync on',
  },
  {
    id = 'POSTURE-002', convar = 'sv_scriptHookAllowed', severity = M.CRITICAL,
    evaluate = function(v)
      local b = truthy(v)
      if b == false or b == nil then return true end -- default is false
      return false, 'sv_scriptHookAllowed is true'
    end,
    impact = 'Script Hook V clients can execute arbitrary native calls locally. '
          .. 'The official documentation states this "makes the server vulnerable to '
          .. 'security issues".',
    remediation = 'set sv_scriptHookAllowed false',
  },
  {
    id = 'POSTURE-003', convar = 'sv_stateBagStrictMode', severity = M.HIGH,
    evaluate = function(v)
      local b = truthy(v)
      if b == true then return true end
      return false, 'sv_stateBagStrictMode is ' .. (b == false and 'false' or 'unset (defaults to false)')
    end,
    impact = 'With strict mode off, the network owner of an entity can modify that '
          .. "entity's state bag AND their own player state bag. Any resource that "
          .. 'trusts player state for a gameplay decision is directly writable by the '
          .. 'player.',
    remediation = 'setr sv_stateBagStrictMode true',
  },
  {
    id = 'POSTURE-004', convar = 'sv_entityLockdown', severity = M.HIGH,
    evaluate = function(v)
      local s = tostring(v or ''):lower()
      if s == 'strict' or s == 'full' then return true end
      if s == 'relaxed' then
        return false, 'sv_entityLockdown is relaxed'
      end
      return false, 'sv_entityLockdown is ' .. (s == '' and 'unset (defaults to inactive)' or s)
    end,
    impact = 'In inactive mode clients can create any entity. This is the mechanism '
          .. 'behind vehicle/ped/object spawning abuse. relaxed blocks only '
          .. 'script-owned client entities; strict blocks all client entity creation.',
    remediation = 'set sv_entityLockdown "strict"   # or "relaxed" if resources need client entities',
  },
  {
    id = 'POSTURE-005', convar = 'sv_filterRequestControl', severity = M.MEDIUM,
    evaluate = function(v)
      local n = as_int(v)
      if n and n >= 1 then return true end
      return false, 'sv_filterRequestControl is ' .. (n and tostring(n) or 'unset (defaults to 0)')
    end,
    impact = 'Mode 0 allows unrestricted REQUEST_CONTROL_EVENT routing, letting a '
          .. "client take control of entities it does not own -- including other "
          .. "players' occupied vehicles.",
    remediation = 'set sv_filterRequestControl 1',
  },
  {
    id = 'POSTURE-006', convar = 'sv_authMinTrust', severity = M.MEDIUM,
    evaluate = function(v)
      local n = as_int(v)
      if n and n >= 2 then return true end
      return false, 'sv_authMinTrust is ' .. (n and tostring(n) or 'unset (defaults to 1)')
    end,
    impact = 'Trust is how unlikely it is that a client can spoof its identity. At the '
          .. 'default of 1 the weakest identity providers are accepted, which weakens '
          .. 'any history or ban keyed on identity.',
    remediation = 'set sv_authMinTrust 2',
  },
  {
    id = 'POSTURE-007', convar = 'sv_authMaxVariance', severity = M.MEDIUM,
    evaluate = function(v)
      local n = as_int(v)
      if n and n <= 4 then return true end
      return false, 'sv_authMaxVariance is ' .. (n and tostring(n) or 'unset (defaults to 5)')
    end,
    impact = "Variance is how likely a player's identifier is to change. At the default "
          .. 'of 5, identifiers are expected to churn, which degrades long-term '
          .. 'behavioural baselines.',
    remediation = 'set sv_authMaxVariance 4',
  },
  {
    id = 'POSTURE-008', convar = 'sv_endpointPrivacy', severity = M.LOW,
    evaluate = function(v)
      local b = truthy(v)
      if b == true then return true end
      return false, 'sv_endpointPrivacy is ' .. (b == false and 'false' or 'unset')
    end,
    impact = 'Player IP addresses appear in public server reports. This is a privacy '
          .. 'exposure for your players rather than a cheat vector.',
    remediation = 'set sv_endpointPrivacy true',
  },
}

M.CHECKS = CHECKS

--- Audit a ConVar snapshot.
-- @param convars table  { ['onesync'] = 'on', ... } as read by the adapter
-- @return findings (list), summary (table)
function M.audit(convars)
  convars = convars or {}
  local findings, summary = {}, {
    total = #CHECKS, passed = 0, failed = 0, worst = nil, worst_rank = 0,
    by_severity = { critical = 0, high = 0, medium = 0, low = 0, info = 0 },
  }

  for _, chk in ipairs(CHECKS) do
    local value = convars[chk.convar]
    local ok, detail = chk.evaluate(value)
    if ok then
      summary.passed = summary.passed + 1
    else
      summary.failed = summary.failed + 1
      summary.by_severity[chk.severity] = summary.by_severity[chk.severity] + 1
      local rank = SEVERITY_RANK[chk.severity] or 0
      if rank > summary.worst_rank then
        summary.worst_rank, summary.worst = rank, chk.severity
      end
      findings[#findings + 1] = {
        id          = chk.id,
        convar      = chk.convar,
        severity    = chk.severity,
        detail      = detail,
        impact      = chk.impact,
        remediation = chk.remediation,
      }
    end
  end

  -- Deterministic order: worst first, then by id. Stable output keeps fixtures
  -- comparable across runs.
  table.sort(findings, function(a, b)
    local ra, rb = SEVERITY_RANK[a.severity] or 0, SEVERITY_RANK[b.severity] or 0
    if ra ~= rb then return ra > rb end
    return a.id < b.id
  end)

  return findings, summary
end

--- True when the server is missing a capability this platform depends on.
-- Distinct from "insecure": a hardening gap is the owner's call, but onesync=off
-- means our telemetry is structurally blind and we must say so loudly.
function M.is_blind(convars)
  local s = tostring((convars or {}).onesync or ''):lower()
  return s ~= 'on', 'onesync must be "on" for server-side game events and camera natives'
end

return M

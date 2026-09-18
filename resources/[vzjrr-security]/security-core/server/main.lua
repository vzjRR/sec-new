--[[
  security-core / server / main.lua

  ADAPTER LAYER -- impure by design. This is the only file in security-core that
  touches natives. It is deliberately thin: it reads the world, hands plain tables to
  the pure modules in lib/, and publishes the results.

  It is NOT unit-tested in CI, because FXServer cannot boot there
  (docs/ENVIRONMENT_AUDIT.md §6.3). Keeping it thin is what keeps the untested
  surface small (docs/ARCHITECTURE.md §2 C2).

  Files are loaded by fxmanifest order, so the lib modules are already global-free
  locals returned by their own chunks -- we re-require them through the resource's
  module loader.
]]

local mode_lib   = require 'lib.mode'
local config_lib = require 'lib.config'
local logger_lib = require 'lib.logger'
local posture_lib= require 'lib.posture'

local RESOURCE = GetCurrentResourceName()

-- ---------------------------------------------------------------------------
-- Clock: the pure modules take injected time sources.
-- ---------------------------------------------------------------------------
local function wall_ms() return math.floor(os.time() * 1000) end
local function mono_ms() return GetGameTimer() end

-- ---------------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------------
local log

local function make_logger(level)
  return logger_lib.new(function(entry)
    -- Human-readable console line, plus a structured trace for monitoring tools.
    -- PRINT_STRUCTURED_TRACE emits JSON on server fd 3 (audit §7.6).
    print(logger_lib.format(entry))
    local ok, encoded = pcall(json.encode, entry)
    if ok and PrintStructuredTrace then
      pcall(PrintStructuredTrace, encoded)
    end
  end, { level = level, component = RESOURCE })
end

-- ---------------------------------------------------------------------------
-- ConVar reading
-- ---------------------------------------------------------------------------
local POSTURE_CONVARS = {
  'onesync', 'sv_scriptHookAllowed', 'sv_stateBagStrictMode', 'sv_entityLockdown',
  'sv_filterRequestControl', 'sv_authMinTrust', 'sv_authMaxVariance',
  'sv_endpointPrivacy',
}

local function read_posture_convars()
  local out = {}
  for _, name in ipairs(POSTURE_CONVARS) do
    -- GetConvar returns the default when unset; we pass a sentinel so "unset" is
    -- distinguishable from "set to something false-ish". The posture module treats
    -- nil as "unset (defaults to ...)".
    local v = GetConvar(name, '__unset__')
    if v ~= '__unset__' then out[name] = v end
  end
  return out
end

--- Read config overrides from ConVars, e.g. security_poll_movement_ms.
local function read_config_overrides()
  local overrides = {}
  for key, spec in pairs(config_lib.SCHEMA) do
    if key ~= 'mode' then
      local convar = 'security_' .. key:gsub('%.', '_')
      local raw = GetConvar(convar, '__unset__')
      if raw ~= '__unset__' then
        if spec.type == 'number' then
          overrides[key] = tonumber(raw)
        elseif spec.type == 'boolean' then
          overrides[key] = (raw == 'true' or raw == '1')
        else
          overrides[key] = raw
        end
      end
    end
  end
  return overrides
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local State = {
  mode        = mode_lib.PRODUCTION,
  config      = config_lib.defaults(),
  started_at  = nil,
  boot_mono   = nil,
  posture     = { findings = {}, summary = nil, checked_at = nil },
  blind       = true,
  blind_reason= nil,
  problems    = {},
  ready       = false,
}

-- ---------------------------------------------------------------------------
-- Posture audit
-- ---------------------------------------------------------------------------
local function run_posture_audit()
  local convars = read_posture_convars()
  local findings, summary = posture_lib.audit(convars)
  local blind, blind_reason = posture_lib.is_blind(convars)

  State.posture = { findings = findings, summary = summary, checked_at = mono_ms() }
  State.blind, State.blind_reason = blind, blind_reason

  if blind then
    -- This is not a hardening suggestion; it means the platform cannot observe.
    log:error('server is not state-aware: this platform is BLIND', {
      reason = blind_reason,
      remediation = 'set onesync on',
    })
  end

  if summary.failed == 0 then
    log:info('convar posture audit: hardened', { checks_n = summary.total })
  else
    log:warn('convar posture audit found issues', {
      failed_n = summary.failed, passed_n = summary.passed, worst = summary.worst,
    })
    for _, f in ipairs(findings) do
      log:warn('posture finding', {
        id = f.id, convar = f.convar, severity = f.severity,
        detail = f.detail, remediation = f.remediation,
      })
    end
  end
  return findings, summary
end

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------
local function boot()
  State.boot_mono = mono_ms()

  local resolved_mode, mode_note = mode_lib.resolve(GetConvar('security_mode', 'PRODUCTION'))
  State.mode = resolved_mode

  local cfg, problems = config_lib.build(read_config_overrides())
  cfg['mode'] = resolved_mode
  State.config, State.problems = cfg, problems

  log = make_logger(cfg['log_level'])

  log:info('starting', {
    resource = RESOURCE,
    version = GetResourceMetadata(RESOURCE, 'version', 0),
    mode = resolved_mode,
  })

  if mode_note then
    -- Fail-closed already happened; say so rather than silently running as PRODUCTION.
    log:warn('mode resolution note', { note = mode_note })
  end
  for _, p in ipairs(problems) do
    log:warn('configuration problem', { problem = p })
  end

  if resolved_mode == mode_lib.LAB then
    log:warn('LAB mode is active: verbose telemetry and lab-only capabilities are enabled',
      { capabilities = 'see docs/ARCHITECTURE.md §6' })
  end

  if cfg['posture.audit_on_boot'] then
    run_posture_audit()
  end

  -- Enforcement is a separate, future system (charter §10, §12). Say it out loud at
  -- boot so nobody deploys this expecting bans.
  log:info('observation only: this build performs no enforcement', {
    detectors_enabled = cfg['detectors.enabled'],
  })

  State.started_at = wall_ms()
  State.ready = true
  log:info('ready', { startup_ms = mono_ms() - State.boot_mono })
end

-- ---------------------------------------------------------------------------
-- Public surface for the other security-* resources
-- ---------------------------------------------------------------------------
local function health()
  return {
    ready        = State.ready,
    resource     = RESOURCE,
    version      = GetResourceMetadata(RESOURCE, 'version', 0),
    mode         = State.mode,
    started_at   = State.started_at,
    uptime_ms    = State.boot_mono and (mono_ms() - State.boot_mono) or 0,
    blind        = State.blind,
    blind_reason = State.blind_reason,
    players_n    = GetNumPlayerIndices and GetNumPlayerIndices() or nil,
    posture      = {
      checked_at = State.posture.checked_at,
      summary    = State.posture.summary,
      findings_n = #State.posture.findings,
    },
    config_problems_n = #State.problems,
    log_counts   = log and log:counts() or nil,
  }
end

exports('health', health)
exports('getMode', function() return State.mode end)
exports('getConfig', function()
  local copy = {}
  for k, v in pairs(State.config) do copy[k] = v end
  return copy -- a copy: no other resource gets to mutate core config
end)
exports('allows', function(capability) return mode_lib.allows(State.mode, capability) end)
exports('getPosture', function() return State.posture end)
exports('isBlind', function() return State.blind, State.blind_reason end)
exports('clockSources', function() return wall_ms, mono_ms end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
AddEventHandler('onResourceStart', function(resource)
  if resource ~= RESOURCE then return end
  local ok, err = pcall(boot)
  if not ok then
    -- A crashed security core must be obvious, not silent.
    print(('[%s] FATAL during boot: %s'):format(RESOURCE, tostring(err)))
  end
end)

AddEventHandler('onResourceStop', function(resource)
  if resource ~= RESOURCE then return end
  State.ready = false
  if log then
    log:info('stopping', { uptime_ms = State.boot_mono and (mono_ms() - State.boot_mono) or 0 })
  end
end)

-- Periodic posture re-check: ConVars can change at runtime.
CreateThread(function()
  while true do
    Wait(State.config['posture.recheck_ms'] or 300000)
    if State.ready and State.config['posture.audit_on_boot'] then
      pcall(run_posture_audit)
    end
  end
end)

-- Status command. Read-only, admin-gated via the standard ACE system.
RegisterCommand('security:status', function(source, _, _)
  if source > 0 and not IsPlayerAceAllowed(tostring(source), 'security.status') then
    return
  end
  local h = health()
  local ok, encoded = pcall(json.encode, h)
  print(('[%s] status: %s'):format(RESOURCE, ok and encoded or '<encode failed>'))
end, false)

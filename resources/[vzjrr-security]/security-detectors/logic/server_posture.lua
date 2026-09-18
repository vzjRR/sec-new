--[[
  security-detectors / logic / server_posture.lua

  PURE LUA. Detector #1: `server.posture`.
  Design spec: detectors/server/POSTURE-AUDIT.md
  Decision:    knowledge/decisions/D-003-posture-audit-ships-first.md

  ---------------------------------------------------------------------------
  WHY THIS IS THE FIRST DETECTOR

  Several FiveM security ConVars default to the permissive setting. On a default
  server clients can write their own player state bag, create arbitrary entities, and
  request control of entities they do not own. A meaningful share of "cheating" on
  such a server is simply PERMITTED BY CONFIGURATION.

  Detecting an abuse the server is configured to allow is strictly worse than
  disallowing it. And uniquely among the planned detectors, this one makes findings
  about the SERVER rather than accusations about a player, so its false-positive risk
  against players is exactly zero.

  ---------------------------------------------------------------------------
  THIS IS A PURE TRANSFORM

  It does not read ConVars. `posture.audit()` lives in security-core, and FiveM
  resources cannot share files, so the adapter calls security-core's export (which
  passes plain tables only) and hands the FINDINGS here. That keeps this module a
  pure function of plain data and free of the cross-resource question entirely.
  ---------------------------------------------------------------------------
]]

local M = {}

M.ID      = 'server.posture'
M.VERSION = 1
M.KIND    = 'periodic'

-- The posture severities map straight through; they were chosen in terms of what the
-- permissive setting makes possible (see the design spec).
local SEVERITY_PASSTHROUGH = {
  critical = 'critical', high = 'high', medium = 'medium', low = 'low', info = 'info',
}

--[[
  An unrecognised severity RAISES rather than defaulting.

  An earlier version fell back to 'info', which is a downgrade -- so a critical
  finding with a typo'd severity would have been reported as informational and
  ignored. Silently weakening a finding is the worst available failure mode here,
  and since these severities come from our own posture module, an unknown one is a
  programming error that should be loud.
]]
local function map_severity(finding)
  local mapped = SEVERITY_PASSTHROUGH[finding.severity or '']
  if not mapped then
    error(string.format(
      'posture finding %s has an unrecognised severity %q; refusing to guess',
      tostring(finding.id), tostring(finding.severity)))
  end
  return mapped
end

--[[
  Build the explanation.

  docs/DETECTION_MODEL.md §2 requires an explanation a human can act on without
  reading the code. For a configuration finding that means three things in order:
  what was observed, what it makes possible, and the exact line to change. A finding
  an operator cannot act on gets ignored or disabled.
]]
local function explain(finding)
  return string.format(
    '%s. Impact: %s Remediation: %s',
    tostring(finding.detail), tostring(finding.impact), tostring(finding.remediation))
end

--[[
  evaluate(context, config) -> { DetectionResult, ... }

  context = {
    findings   = <list from posture.audit()>,
    summary    = <table from posture.audit()>,
    blind      = boolean,
    blind_reason = string|nil,
    ts = <ms>, mono = <ms>,
  }

  deps.detection_new is injected at construction by `M.detector(deps)`.
]]
function M.detector(deps)
  assert(type(deps) == 'table' and type(deps.detection_new) == 'function',
    'server_posture: deps.detection_new required')
  local detection_new = deps.detection_new

  return function(context, config)
    context = context or {}
    local results = {}

    local ts   = context.ts or 0
    local mono = context.mono or 0

    for _, f in ipairs(context.findings or {}) do
      local severity = map_severity(f)

      local result, errs = detection_new({
        detector_id      = M.ID,
        detector_version = M.VERSION,
        -- The subject is the server, not a person. docs/TELEMETRY_SCHEMA.md §2
        -- reserves 'SYSTEM' for exactly this.
        player_key       = 'SYSTEM',
        ts               = ts,
        mono             = mono,
        signal           = tostring(f.id or 'POSTURE-UNKNOWN'),
        severity         = severity,
        --[[
          Confidence 1.0, and legitimately so -- unlike anywhere else in this
          project. This is a direct read of server configuration, not an inference
          about behaviour. There is nothing probabilistic about sv_entityLockdown
          being 'inactive'. The trust basis is 'observed' (the server read its own
          ConVars), so the claimed-only cap does not apply and no cap is triggered.
        ]]
        confidence       = 1.0,
        trust_levels     = { 'observed' },
        sources          = { 'convar:' .. tostring(f.convar or 'unknown') },
        measurements     = {},
        explanation      = explain(f),
        context          = {
          convar      = f.convar,
          finding_id   = f.id,
          remediation = f.remediation,
        },
      })

      if result then
        results[#results + 1] = result
      else
        -- A malformed finding must not silently vanish. Surfacing it as a detector
        -- error is better than dropping a real configuration problem.
        error(string.format('could not build a result for %s: %s',
          tostring(f.id), table.concat(errs or {}, '; ')))
      end
    end

    --[[
      Blindness is reported separately from the hardening findings.

      A hardening gap is the operator's judgement call. `onesync` not being 'on' is
      different in kind: the platform is then structurally unable to observe combat,
      aim or entities at all. Folding it in with the advisory findings would let the
      single most important fact about the deployment be skimmed past.
    ]]
    if context.blind then
      local result = detection_new({
        detector_id      = M.ID,
        detector_version = M.VERSION,
        player_key       = 'SYSTEM',
        ts               = ts,
        mono             = mono,
        signal           = 'PLATFORM-BLIND',
        severity         = 'critical',
        confidence       = 1.0,
        trust_levels     = { 'observed' },
        sources          = { 'convar:onesync' },
        measurements     = {},
        explanation      = 'The server is not state-aware: '
          .. tostring(context.blind_reason or 'onesync is not "on"')
          .. '. Impact: the server-side game events and camera natives this platform '
          .. 'depends on do not exist, so no combat, aim or entity telemetry can be '
          .. 'collected at all. This is not a hardening suggestion -- the platform is '
          .. 'structurally blind until it is fixed. Remediation: set onesync on',
        context          = { convar = 'onesync', finding_id = 'PLATFORM-BLIND' },
      })
      if result then results[#results + 1] = result end
    end

    return results
  end
end

--- Convenience: the registration spec for the registry.
function M.spec(deps)
  return {
    id      = M.ID,
    version = M.VERSION,
    kind    = M.KIND,
    fn      = M.detector(deps),
  }
end

--[[
  DUAL EXPORT -- see docs/ARCHITECTURE.md §3.2 "Module loading".
]]
SecLab = SecLab or {}
SecLab.server_posture = M

return M

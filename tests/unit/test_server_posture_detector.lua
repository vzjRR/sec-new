--[[
  tests/unit/test_server_posture_detector.lua

  Detector #1, end to end: real ConVar snapshot -> posture.audit -> DetectionResults
  -> registry -> incident -> investigation bundle.

  This is the first full vertical slice the project has, and it is worth exercising as
  one because each layer's guarantees only matter if they compose.
]]
local H = ...
local posture_lib  = require('lib.posture')
local sp           = require('logic.server_posture')
local registry     = require('logic.registry')
local detection    = require('logic.detection')
local incident_lib = require('logic.incident')
local investigation= require('logic.investigation')

local function detector()
  return sp.detector({ detection_new = detection.new })
end

local function audit(convars)
  local findings, summary = posture_lib.audit(convars)
  local blind, blind_reason = posture_lib.is_blind(convars)
  return { findings = findings, summary = summary, blind = blind,
           blind_reason = blind_reason, ts = 1758204000000, mono = 500 }
end

local HARDENED = {
  onesync = 'on', sv_scriptHookAllowed = 'false', sv_stateBagStrictMode = 'true',
  sv_entityLockdown = 'strict', sv_filterRequestControl = '1',
  sv_authMinTrust = '2', sv_authMaxVariance = '4', sv_endpointPrivacy = 'true',
}

local CFG = { ['detectors.enabled'] = true }

H.suite('server.posture: construction')

H.test('requires an injected detection_new', function()
  H.eq(pcall(sp.detector, {}), false)
  H.eq(pcall(sp.detector, { detection_new = 'nope' }), false)
end)

H.test('exposes a registry spec', function()
  local spec = sp.spec({ detection_new = detection.new })
  H.eq(spec.id, 'server.posture')
  H.eq(spec.kind, 'periodic')
  H.eq(type(spec.fn), 'function')
  H.eq(spec.version, sp.VERSION)
end)

H.suite('server.posture: a hardened server produces nothing')

H.test('no findings means no detections', function()
  -- A detector that fires on a correctly configured server is a false-positive
  -- generator aimed at the operator.
  local results = detector()(audit(HARDENED), CFG)
  H.eq(#results, 0)
end)

H.suite('server.posture: a default server')

H.test('an unconfigured server produces detections for each finding', function()
  local ctx = audit({})
  local results = detector()(ctx, CFG)
  H.eq(#results, #ctx.findings + 1, 'one per finding, plus the blindness detection')
end)

H.test('the subject is the SERVER, never a player', function()
  -- The whole reason this detector ships first: zero false-positive risk against
  -- players, because no player is named.
  for _, r in ipairs(detector()(audit({}), CFG)) do
    H.eq(r.player_key, 'SYSTEM', r.signal .. ' must not name a player')
  end
end)

H.test('confidence is 1.0 and legitimately uncapped', function()
  --[[
    Unlike anywhere else in the project: this is a direct read of server
    configuration, not an inference about behaviour. The trust basis is 'observed',
    so the claimed-only cap does not apply.
  ]]
  for _, r in ipairs(detector()(audit({}), CFG)) do
    H.eq(r.confidence, 1.0, r.signal)
    H.eq(#r.confidence_caps, 0, r.signal .. ' should trigger no caps')
    H.eq(r.trust_basis[1], 'observed')
  end
end)

H.test('the signal is the posture finding id', function()
  local seen = {}
  for _, r in ipairs(detector()(audit({}), CFG)) do seen[r.signal] = true end
  for _, id in ipairs({ 'POSTURE-001', 'POSTURE-003', 'POSTURE-004', 'POSTURE-005' }) do
    H.ok(seen[id], 'expected a detection for ' .. id)
  end
end)

H.test('severity passes through from the posture check', function()
  local by_signal = {}
  for _, r in ipairs(detector()(audit({}), CFG)) do by_signal[r.signal] = r end
  H.eq(by_signal['POSTURE-001'].severity, 'critical')
  H.eq(by_signal['POSTURE-003'].severity, 'high')
  H.eq(by_signal['POSTURE-005'].severity, 'medium')
end)

H.suite('server.posture: the explanation must be actionable')

H.test('every explanation states the observation, the impact and the fix', function()
  -- A finding an operator cannot act on gets ignored or disabled.
  for _, r in ipairs(detector()(audit({}), CFG)) do
    H.ok(r.explanation:find('Impact:', 1, true), r.signal .. ' needs an impact')
    H.ok(r.explanation:find('Remediation:', 1, true), r.signal .. ' needs a remediation')
    H.ok(#r.explanation > 80, r.signal .. ' explanation is too thin')
  end
end)

H.test('the remediation is a copy-pasteable server.cfg line', function()
  local by_signal = {}
  for _, r in ipairs(detector()(audit({}), CFG)) do by_signal[r.signal] = r end
  H.ok(by_signal['POSTURE-003'].context.remediation:find('sv_stateBagStrictMode', 1, true))
  H.ok(by_signal['POSTURE-004'].context.remediation:find('sv_entityLockdown', 1, true))
end)

H.test('the offending convar is named in context', function()
  local by_signal = {}
  for _, r in ipairs(detector()(audit({}), CFG)) do by_signal[r.signal] = r end
  H.eq(by_signal['POSTURE-001'].context.convar, 'onesync')
  H.eq(by_signal['POSTURE-002'] , nil, 'scriptHook defaults to false and must not fire')
end)

H.suite('server.posture: blindness is reported separately')

H.test('onesync off produces a distinct PLATFORM-BLIND detection', function()
  --[[
    A hardening gap is the operator's judgement call. onesync not being 'on' is
    different in kind: the platform then cannot observe anything. Folding it in with
    the advisory findings would let the most important fact about the deployment be
    skimmed past.
  ]]
  local found
  for _, r in ipairs(detector()(audit({ onesync = 'off' }), CFG)) do
    if r.signal == 'PLATFORM-BLIND' then found = r end
  end
  H.ok(found, 'expected a PLATFORM-BLIND detection')
  H.eq(found.severity, 'critical')
  H.ok(found.explanation:find('structurally blind', 1, true),
    'the explanation must say the platform cannot observe, not merely advise')
  H.ok(found.explanation:find('set onesync on', 1, true))
end)

H.test('a state-aware server produces no blindness detection', function()
  for _, r in ipairs(detector()(audit(HARDENED), CFG)) do
    H.ok(r.signal ~= 'PLATFORM-BLIND')
  end
end)

H.test('a hardened-but-blind server still reports blindness', function()
  local cv = {}
  for k, v in pairs(HARDENED) do cv[k] = v end
  cv.onesync = 'legacy'
  local signals = {}
  for _, r in ipairs(detector()(audit(cv), CFG)) do signals[r.signal] = true end
  H.ok(signals['PLATFORM-BLIND'], 'legacy onesync is still not state-aware')
  H.ok(signals['POSTURE-001'], 'and it is still a posture finding')
end)

H.suite('server.posture: robustness')

H.test('survives an empty context', function()
  H.eq(#detector()({}, CFG), 0)
  H.eq(#detector()(nil, CFG), 0)
end)

H.test('an unrecognised severity raises instead of being downgraded', function()
  --[[
    An earlier version fell back to 'info', which is a DOWNGRADE: a critical finding
    with a typo'd severity would have been reported as informational and ignored.
    Silently weakening a finding is the worst failure mode available here.
  ]]
  local ok, err = pcall(detector(), {
    findings = { { id = 'BAD', severity = 'nonsense' } }, ts = 1, mono = 1,
  }, CFG)
  H.eq(ok, false, 'an unknown severity must raise, not default to info')
  H.ok(tostring(err):find('refusing to guess', 1, true), 'got: ' .. tostring(err))
end)

H.test('every posture severity the audit can emit is mappable', function()
  -- Guards the pairing between posture.lua's severities and this detector's map:
  -- if posture gains a severity, this test fails rather than the detector raising
  -- on a live server.
  local posture = require('lib.posture')
  for _, chk in ipairs(posture.CHECKS) do
    local ok = pcall(detector(), {
      -- Realistic lengths: the DetectionResult type rejects an explanation under
      -- 30 characters, and the explanation is built from these three fields.
      findings = { { id = chk.id, severity = chk.severity,
                     detail = chk.convar .. ' is set to a permissive value',
                     impact = chk.impact, remediation = chk.remediation,
                     convar = chk.convar } },
      ts = 1, mono = 1,
    }, CFG)
    H.ok(ok, ('severity %q used by %s is not mappable'):format(
      tostring(chk.severity), chk.id))
  end
end)

H.suite('server.posture: the full vertical slice')

H.test('audit -> detector -> registry -> incident -> bundle', function()
  local r = registry.new({ detection_new = detection.new })
  H.ok((r:register(sp.spec({ detection_new = detection.new }))))

  local results, errors = r:run_periodic(audit({}), CFG)
  H.eq(#errors, 0, 'registry rejected results: ' .. (errors[1] and errors[1].err or ''))
  H.ok(#results >= 7)

  -- Posture detections are about the server, so the incident is keyed to SYSTEM.
  local inc = incident_lib.new{ id = 'INC-POSTURE-1', player_key = 'SYSTEM',
                                ts = 1758204000000, mono = 500 }
  for _, d in ipairs(results) do
    local ok, err = inc:add_detection(d)
    H.ok(ok, 'incident rejected a detection: ' .. tostring(err))
  end

  H.eq(inc:confidence(), 1.0)
  H.eq(inc:severity(), 'critical')
  H.eq(inc:distinct_detectors(), 1)

  local bundle = investigation.build(inc, {}, { store_complete = true })
  H.eq(#bundle.detections, #results)

  local text = investigation.render(bundle)
  H.ok(text:find('server.posture', 1, true))
  H.ok(text:find('POSTURE-', 1, true))

  --[[
    The bundle is flagged as single-source, and that is CORRECT: one detector is
    carrying the whole conclusion, and correlation across independent signals is
    Phase 5. The review layer noticing this is the system working, not failing.
  ]]
  local codes = {}
  for _, p in ipairs(bundle.review.problems) do codes[p.code] = true end
  H.ok(codes['single_detector_high_confidence'],
    'a lone detector at confidence 1.0 should be flagged as single-source')
end)

H.test('the registry enforces attribution on this detector too', function()
  local r = registry.new({ detection_new = detection.new })
  r:register(sp.spec({ detection_new = detection.new }))
  local results = r:run_periodic(audit({}), CFG)
  for _, d in ipairs(results) do
    H.eq(d.detector_id, 'server.posture')
    H.eq(d.detector_version, sp.VERSION)
  end
end)

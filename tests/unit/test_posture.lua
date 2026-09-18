--[[
  tests/unit/test_posture.lua

  The ConVar posture audit is the first detector the roadmap ships
  (docs/ENVIRONMENT_AUDIT.md §10.2) precisely because it makes findings about the
  SERVER rather than accusations about players. These tests verify it is accurate
  about defaults -- being wrong here would send an owner chasing a non-problem.
]]
local H = ...
local posture = require('lib.posture')

-- A fully hardened server, per the remediation lines in lib/posture.lua.
local function hardened(over)
  local c = {
    onesync                 = 'on',
    sv_scriptHookAllowed    = 'false',
    sv_stateBagStrictMode   = 'true',
    sv_entityLockdown       = 'strict',
    sv_filterRequestControl = '1',
    sv_authMinTrust         = '2',
    sv_authMaxVariance      = '4',
    sv_endpointPrivacy      = 'true',
  }
  for k, v in pairs(over or {}) do
    if v == '__nil__' then c[k] = nil else c[k] = v end
  end
  return c
end

local function find(findings, id)
  for _, f in ipairs(findings) do if f.id == id then return f end end
  return nil
end

H.suite('posture: hardened baseline')

H.test('a hardened server produces no findings', function()
  local findings, summary = posture.audit(hardened())
  H.eq(#findings, 0, 'unexpected findings: ' .. (findings[1] and findings[1].id or ''))
  H.eq(summary.failed, 0)
  H.eq(summary.passed, summary.total)
end)

H.test('entityLockdown full is also acceptable', function()
  H.eq(#posture.audit(hardened{ sv_entityLockdown = 'full' }), 0)
end)

H.suite('posture: an out-of-the-box server')

-- Every one of these is the DOCUMENTED default (audit §7.7). If this test ever
-- fails, either the platform changed its defaults or our audit was wrong.
H.test('an unconfigured server trips every hardening check', function()
  local findings, summary = posture.audit({})
  H.ok(summary.failed >= 7, 'expected most checks to fail on an empty config, got '
    .. tostring(summary.failed))
  H.ok(find(findings, 'POSTURE-001'), 'onesync unset must be flagged')
  H.ok(find(findings, 'POSTURE-003'), 'sv_stateBagStrictMode defaults to false')
  H.ok(find(findings, 'POSTURE-004'), 'sv_entityLockdown defaults to inactive')
  H.ok(find(findings, 'POSTURE-005'), 'sv_filterRequestControl defaults to 0')
  H.ok(find(findings, 'POSTURE-006'), 'sv_authMinTrust defaults to 1')
  H.ok(find(findings, 'POSTURE-007'), 'sv_authMaxVariance defaults to 5')
end)

H.test('sv_scriptHookAllowed unset is NOT flagged, because it defaults to false', function()
  -- Getting this backwards would generate a finding on every correctly configured
  -- server -- a false positive against the owner.
  H.is_nil(find(posture.audit({}), 'POSTURE-002'))
end)

H.suite('posture: individual checks')

H.test('onesync off or legacy is critical', function()
  for _, v in ipairs({ 'off', 'legacy' }) do
    local f = find(posture.audit(hardened{ onesync = v }), 'POSTURE-001')
    H.ok(f, 'onesync=' .. v .. ' must be flagged')
    H.eq(f.severity, posture.CRITICAL)
  end
end)

H.test('script hook enabled is critical', function()
  local f = find(posture.audit(hardened{ sv_scriptHookAllowed = 'true' }), 'POSTURE-002')
  H.ok(f); H.eq(f.severity, posture.CRITICAL)
end)

H.test('state bag strict mode false is high', function()
  local f = find(posture.audit(hardened{ sv_stateBagStrictMode = 'false' }), 'POSTURE-003')
  H.ok(f); H.eq(f.severity, posture.HIGH)
  H.ok(f.detail:find('false', 1, true))
end)

H.test('entity lockdown relaxed is still reported, at high', function()
  -- relaxed is better than inactive but still permits non-script client entities.
  local f = find(posture.audit(hardened{ sv_entityLockdown = 'relaxed' }), 'POSTURE-004')
  H.ok(f, 'relaxed should be surfaced so the owner makes a conscious choice')
  H.ok(f.detail:find('relaxed', 1, true))
end)

H.test('filterRequestControl accepts modes 1 through 3', function()
  for _, v in ipairs({ '1', '2', '3' }) do
    H.is_nil(find(posture.audit(hardened{ sv_filterRequestControl = v }), 'POSTURE-005'),
      'mode ' .. v .. ' should pass')
  end
  H.ok(find(posture.audit(hardened{ sv_filterRequestControl = '0' }), 'POSTURE-005'))
end)

H.suite('posture: value parsing')

H.test('booleans are accepted as strings, numbers or real booleans', function()
  for _, v in ipairs({ 'true', '1', 'yes', 'TRUE' }) do
    H.is_nil(find(posture.audit(hardened{ sv_stateBagStrictMode = v }), 'POSTURE-003'),
      'value ' .. tostring(v) .. ' should read as true')
  end
  H.is_nil(find(posture.audit(hardened{ sv_stateBagStrictMode = true }), 'POSTURE-003'))
end)

H.test('a garbage boolean value is treated as not-hardened', function()
  -- Ambiguity must resolve toward reporting, not toward silence.
  H.ok(find(posture.audit(hardened{ sv_stateBagStrictMode = 'maybe' }), 'POSTURE-003'))
end)

H.test('integers are parsed from strings and numbers', function()
  H.is_nil(find(posture.audit(hardened{ sv_authMinTrust = 3 }), 'POSTURE-006'))
  H.is_nil(find(posture.audit(hardened{ sv_authMinTrust = '3' }), 'POSTURE-006'))
  H.ok(find(posture.audit(hardened{ sv_authMinTrust = 'three' }), 'POSTURE-006'))
end)

H.suite('posture: finding quality')

H.test('every finding carries impact and a concrete remediation', function()
  -- A finding an owner cannot act on will be ignored or disabled.
  local findings = posture.audit({})
  H.ok(#findings > 0)
  for _, f in ipairs(findings) do
    H.ok(f.impact and #f.impact > 40, f.id .. ' needs a substantive impact statement')
    H.ok(f.remediation and #f.remediation > 5, f.id .. ' needs a remediation line')
    H.ok(f.detail and #f.detail > 0, f.id .. ' needs an observed detail')
    H.ok(f.convar and #f.convar > 0, f.id .. ' must name its convar')
  end
end)

H.test('findings are ordered worst-first and deterministically', function()
  local findings = posture.audit({})
  local rank = { critical = 5, high = 4, medium = 3, low = 2, info = 1 }
  for i = 2, #findings do
    local prev, cur = findings[i - 1], findings[i]
    H.ok(rank[prev.severity] >= rank[cur.severity], 'severity must not increase down the list')
    if prev.severity == cur.severity then
      H.ok(prev.id < cur.id, 'equal severities must be id-ordered for stable output')
    end
  end
end)

H.test('summary counts by severity and names the worst', function()
  local _, summary = posture.audit({})
  H.eq(summary.worst, posture.CRITICAL)
  H.ok(summary.by_severity.critical >= 1)
  H.eq(summary.passed + summary.failed, summary.total)
end)

H.test('check ids are unique', function()
  local seen = {}
  for _, c in ipairs(posture.CHECKS) do
    H.is_nil(seen[c.id], 'duplicate check id ' .. c.id)
    seen[c.id] = true
  end
end)

H.suite('posture: blindness is distinct from insecurity')

H.test('onesync off means the platform is structurally blind', function()
  -- A hardening gap is the owner's call; being unable to observe anything is not.
  local blind, why = posture.is_blind({ onesync = 'off' })
  H.eq(blind, true)
  H.ok(why:find('onesync', 1, true))
end)

H.test('onesync on means not blind', function()
  H.eq((posture.is_blind({ onesync = 'on' })), false)
end)

H.test('a missing onesync convar counts as blind', function()
  H.eq((posture.is_blind({})), true)
end)

H.test('audit tolerates a nil input', function()
  local findings = posture.audit(nil)
  H.ok(#findings > 0, 'nil config should behave like an empty one, not crash')
end)

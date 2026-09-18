--[[
  tests/unit/test_mode.lua

  Mode resolution must FAIL CLOSED. The failure this guards against is a scenario
  simulator or synthetic event injector activating on a live server because someone
  mistyped a ConVar (docs/ARCHITECTURE.md §6).
]]
local H = ...
local mode = require('lib.mode')

H.suite('mode: resolution')

H.test('recognises LAB', function()
  local m, note = mode.resolve('LAB')
  H.eq(m, mode.LAB); H.is_nil(note)
end)

H.test('recognises PRODUCTION', function()
  local m, note = mode.resolve('PRODUCTION')
  H.eq(m, mode.PRODUCTION); H.is_nil(note)
end)

H.test('is case and whitespace insensitive', function()
  H.eq((mode.resolve('  lab  ')), mode.LAB)
  H.eq((mode.resolve('Lab')), mode.LAB)
  H.eq((mode.resolve('production')), mode.PRODUCTION)
end)

H.suite('mode: fails closed')

H.test('an unrecognised value becomes PRODUCTION and reports why', function()
  local m, note = mode.resolve('labb')
  H.eq(m, mode.PRODUCTION, 'a typo must not yield LAB')
  H.ok(note and note:find('not recognised'), 'expected an explanatory note')
end)

H.test('an empty string becomes PRODUCTION with a note', function()
  local m, note = mode.resolve('')
  H.eq(m, mode.PRODUCTION)
  H.ok(note and note:find('empty'))
end)

H.test('nil becomes PRODUCTION with a note', function()
  local m, note = mode.resolve(nil)
  H.eq(m, mode.PRODUCTION)
  H.ok(note ~= nil)
end)

H.test('a non-string becomes PRODUCTION', function()
  H.eq((mode.resolve(1)), mode.PRODUCTION)
  H.eq((mode.resolve(true)), mode.PRODUCTION)
  H.eq((mode.resolve({})), mode.PRODUCTION)
end)

H.suite('mode: capability gating')

H.test('lab-only capabilities are denied in PRODUCTION', function()
  for _, cap in ipairs({ 'synthetic_events', 'scenario_simulators',
                         'experimental_detectors', 'developer_commands',
                         'raw_payload_capture', 'verbose_telemetry' }) do
    H.eq(mode.allows(mode.PRODUCTION, cap), false, cap .. ' must be denied in PRODUCTION')
    H.eq(mode.allows(mode.LAB, cap), true, cap .. ' should be allowed in LAB')
  end
end)

H.test('core capabilities are allowed in both modes', function()
  for _, cap in ipairs({ 'core_telemetry', 'detection' }) do
    H.eq(mode.allows(mode.LAB, cap), true)
    H.eq(mode.allows(mode.PRODUCTION, cap), true)
  end
end)

H.test('an UNKNOWN capability is denied, not allowed', function()
  -- Adding a lab feature without registering it must not leave it on in production.
  H.eq(mode.allows(mode.LAB, 'not_a_real_capability'), false)
  H.eq(mode.allows(mode.PRODUCTION, 'not_a_real_capability'), false)
end)

H.test('an unknown mode string denies everything', function()
  H.eq(mode.allows('WHATEVER', 'core_telemetry'), false)
end)

H.suite('mode: require_lab guard')

H.test('permits in LAB', function()
  local ok, reason = mode.require_lab(mode.LAB, 'AIM-001 simulator')
  H.eq(ok, true); H.is_nil(reason)
end)

H.test('refuses in PRODUCTION and names the operation', function()
  local ok, reason = mode.require_lab(mode.PRODUCTION, 'AIM-001 simulator')
  H.eq(ok, false)
  H.ok(reason:find('AIM-001 simulator', 1, true), 'reason should name the operation')
  H.ok(reason:find('PRODUCTION', 1, true))
end)

H.test('capabilities() reports the full matrix', function()
  local prod = mode.capabilities(mode.PRODUCTION)
  H.eq(prod.core_telemetry, true)
  H.eq(prod.scenario_simulators, false)
end)

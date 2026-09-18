--[[
  tests/unit/test_config.lua
  Bad config is a self-inflicted outage (a 0ms poll interval) or a mass false
  positive (a negative threshold), so validation is tested as a safety feature.
]]
local H = ...
local config = require('lib.config')

H.suite('config: defaults')

H.test('defaults validate against their own schema', function()
  local ok, errs = config.validate(config.defaults())
  H.ok(ok, table.concat(errs, '; '))
end)

H.test('detection is OFF by default -- Phase 2 observes only', function()
  -- charter §4: build the observatory first. Shipping with detectors on would
  -- contradict the roadmap and produce findings from untested detectors.
  H.eq(config.defaults()['detectors.enabled'], false)
end)

H.test('mode defaults to PRODUCTION', function()
  H.eq(config.defaults()['mode'], 'PRODUCTION')
end)

H.test('record validation is on by default', function()
  H.eq(config.defaults()['telemetry.validate_records'], true)
end)

H.test('network polling default respects the 10s server refresh', function()
  -- audit §7.5: peer statistics only update every 10 seconds.
  H.eq(config.defaults()['poll.network_ms'], 10000)
end)

H.suite('config: validation')

H.test('rejects an unknown key', function()
  local ok, errs = config.validate({ ['nope.nope'] = 1 })
  H.rejects(ok, errs, 'unknown config key')
end)

H.test('rejects a wrong type', function()
  local ok, errs = config.validate({ ['telemetry.enabled'] = 'yes' })
  H.rejects(ok, errs, 'expected boolean')
end)

H.test('rejects a value outside an enum', function()
  local ok, errs = config.validate({ ['log_level'] = 'chatty' })
  H.rejects(ok, errs, 'not one of')
end)

H.test('rejects a below-minimum poll interval', function()
  -- A 0ms interval would busy-loop the game server.
  local ok, errs = config.validate({ ['poll.movement_ms'] = 0 })
  H.rejects(ok, errs, 'below the minimum')
end)

H.test('rejects an above-maximum buffer', function()
  local ok, errs = config.validate({ ['telemetry.buffer_size'] = 10 ^ 9 })
  H.rejects(ok, errs, 'above the maximum')
end)

H.test('rejects NaN', function()
  local ok, errs = config.validate({ ['poll.aim_ms'] = 0/0 })
  H.rejects(ok, errs, 'NaN')
end)

H.test('rejects a non-table config', function()
  local ok, errs = config.validate('nope')
  H.rejects(ok, errs, 'not a table')
end)

H.suite('config: build keeps the server observable')

H.test('applies a valid override', function()
  local cfg, problems = config.build({ ['poll.movement_ms'] = 2000 })
  H.eq(cfg['poll.movement_ms'], 2000)
  H.eq(#problems, 0)
end)

H.test('an invalid override keeps the default and reports the problem', function()
  -- Refusing to boot over one bad line would leave the server with NO
  -- observability, which is worse than running with a sane default.
  local cfg, problems = config.build({ ['poll.movement_ms'] = 1 })
  H.eq(cfg['poll.movement_ms'], config.SCHEMA['poll.movement_ms'].default)
  H.eq(#problems, 1)
  H.ok(problems[1]:find('rejected', 1, true))
  H.ok(problems[1]:find('poll.movement_ms', 1, true))
end)

H.test('an unknown override is ignored and reported', function()
  local cfg, problems = config.build({ ['made.up'] = 1 })
  H.is_nil(cfg['made.up'])
  H.eq(#problems, 1)
  H.ok(problems[1]:find('unknown', 1, true))
end)

H.test('one bad override does not discard the good ones', function()
  local cfg, problems = config.build({
    ['poll.movement_ms'] = 2000,   -- valid
    ['log_level']        = 'loud', -- invalid
    ['telemetry.sink']   = 'memory',
  })
  H.eq(cfg['poll.movement_ms'], 2000)
  H.eq(cfg['telemetry.sink'], 'memory')
  H.eq(cfg['log_level'], 'info', 'bad value must fall back to the default')
  H.eq(#problems, 1)
end)

H.test('build with no overrides equals defaults', function()
  local cfg = config.build(nil)
  for k, v in pairs(config.defaults()) do H.eq(cfg[k], v, k) end
end)

H.test('the result of build always validates', function()
  local cfg = config.build({ ['poll.aim_ms'] = -5, ['bogus'] = true })
  local ok, errs = config.validate(cfg)
  H.ok(ok, table.concat(errs, '; '))
end)

H.suite('config: schema hygiene')

H.test('every key documents itself', function()
  for k, spec in pairs(config.SCHEMA) do
    H.ok(spec.doc and #spec.doc > 10, k .. ' needs a doc string')
    H.ok(spec.type ~= nil, k .. ' needs a type')
    H.eq(type(spec.default), spec.type, k .. ' default must match its declared type')
  end
end)

H.test('every numeric key is bounded on both sides', function()
  -- An unbounded numeric config value is an unexploded footgun.
  for k, spec in pairs(config.SCHEMA) do
    if spec.type == 'number' then
      H.ok(spec.min ~= nil, k .. ' needs a minimum')
      H.ok(spec.max ~= nil, k .. ' needs a maximum')
      H.ok(spec.min <= spec.default and spec.default <= spec.max,
        k .. ' default must sit inside its own bounds')
    end
  end
end)

H.test('describe() renders every key', function()
  local text = config.describe()
  for k in pairs(config.SCHEMA) do
    H.ok(text:find(k, 1, true), 'describe() omitted ' .. k)
  end
end)

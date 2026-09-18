--[[ tests/unit/test_logger.lua ]]
local H = ...
local logger = require('lib.logger')
local clock  = require('logic.clock')

local function capture(opts)
  local out = {}
  local lg = logger.new(function(e) out[#out + 1] = e end, opts)
  return lg, out
end

H.suite('logger: basics')

H.test('requires a writer function', function()
  H.eq(pcall(logger.new, nil, {}), false)
end)

H.test('rejects an unknown level', function()
  H.eq(pcall(logger.new, function() end, { level = 'shout' }), false)
end)

H.test('writes a structured entry', function()
  local lg, out = capture({ component = 'security-core' })
  lg:info('booted', { mode = 'LAB' })
  H.eq(#out, 1)
  H.eq(out[1].level, 'info')
  H.eq(out[1].component, 'security-core')
  H.eq(out[1].msg, 'booted')
  H.eq(out[1].mode, 'LAB')
end)

H.suite('logger: level filtering')

H.test('suppresses below the minimum level', function()
  local lg, out = capture({ level = 'warn' })
  lg:debug('x'); lg:info('y')
  H.eq(#out, 0)
  lg:warn('z'); lg:error('w')
  H.eq(#out, 2)
end)

H.test('reports whether an entry was emitted', function()
  local lg = capture({ level = 'warn' })
  H.eq(lg:debug('x'), false)
  H.eq(lg:error('y'), true)
end)

H.test('level can be changed at runtime', function()
  local lg, out = capture({ level = 'error' })
  lg:info('no')
  H.eq(lg:set_level('debug'), true)
  lg:info('yes')
  H.eq(#out, 1)
  H.eq(lg:set_level('nonsense'), false)
end)

H.suite('logger: field safety')

H.test('a caller field cannot overwrite the level', function()
  -- Otherwise a careless call site could disguise an error as debug output.
  local lg, out = capture({})
  lg:error('real problem', { level = 'debug', component = 'fake' })
  H.eq(out[1].level, 'error')
  H.eq(out[1].component, 'security')
end)

H.test('a caller field cannot overwrite the message', function()
  local lg, out = capture({})
  lg:info('true message', { msg = 'spoofed' })
  H.eq(out[1].msg, 'true message')
end)

H.suite('logger: counts and clock')

H.test('counts emitted entries per level', function()
  local lg = capture({ level = 'debug' })
  lg:debug('a'); lg:info('b'); lg:info('c'); lg:error('d')
  local c = lg:counts()
  H.eq(c.debug, 1); H.eq(c.info, 2); H.eq(c.error, 1); H.eq(c.warn, 0)
end)

H.test('suppressed entries are not counted', function()
  local lg = capture({ level = 'error' })
  lg:info('x')
  H.eq(lg:counts().info, 0)
end)

H.test('stamps times when a clock is supplied', function()
  local c = clock.new(function() return 1758204000000 end, function() return 77 end)
  local lg, out = capture({ clock = c })
  lg:info('hi')
  H.eq(out[1].ts, 1758204000000)
  H.eq(out[1].mono, 77)
end)

H.test('works without a clock', function()
  local lg, out = capture({})
  lg:info('hi')
  H.is_nil(out[1].ts)
end)

H.suite('logger: formatting')

H.test('format renders level, component, message and sorted fields', function()
  local line = logger.format({
    level = 'warn', component = 'security-core', msg = 'posture', failed = 3, worst = 'high',
  })
  H.ok(line:find('WARN', 1, true))
  H.ok(line:find('security-core', 1, true))
  H.ok(line:find('posture', 1, true))
  H.ok(line:find('failed=3', 1, true))
  H.ok(line:find('worst=high', 1, true))
end)

H.test('format is deterministic regardless of field insertion order', function()
  local a = logger.format({ level = 'info', msg = 'm', component = 'c', x = 1, y = 2 })
  local b = logger.format({ level = 'info', msg = 'm', component = 'c', y = 2, x = 1 })
  H.eq(a, b)
end)

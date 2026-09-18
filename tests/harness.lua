--[[
  tests/harness.lua -- minimal pure-Lua test harness.

  Deliberately dependency-free: the build container has vanilla Lua 5.4 and nothing
  else (docs/ENVIRONMENT_AUDIT.md §4.3), and a security project should not pull a
  test framework off the internet to check its own detectors.
]]

local H = {}

local RESET, RED, GREEN, YELLOW = '\27[0m', '\27[31m', '\27[32m', '\27[33m'

H.suites = {}
local current

function H.suite(name)
  current = { name = name, cases = {} }
  H.suites[#H.suites + 1] = current
end

function H.test(name, fn)
  assert(current, 'call H.suite(name) before H.test')
  current.cases[#current.cases + 1] = { name = name, fn = fn }
end

local function fail(msg, level)
  error({ __assert = true, msg = msg }, (level or 2) + 1)
end

function H.ok(v, msg)
  if not v then fail(msg or ('expected truthy, got ' .. tostring(v))) end
end

function H.eq(got, want, msg)
  if got ~= want then
    fail(string.format('%sexpected %s, got %s',
      msg and (msg .. ': ') or '', tostring(want), tostring(got)))
  end
end

function H.near(got, want, tol, msg)
  tol = tol or 1e-9
  if type(got) ~= 'number' then
    fail(string.format('%sexpected a number, got %s', msg and (msg..': ') or '', tostring(got)))
  end
  if math.abs(got - want) > tol then
    fail(string.format('%sexpected %s +/- %s, got %s',
      msg and (msg .. ': ') or '', tostring(want), tostring(tol), tostring(got)))
  end
end

function H.is_nil(v, msg)
  if v ~= nil then fail(msg or ('expected nil, got ' .. tostring(v))) end
end

--- Assert a schema validation failed AND that some error mentions `needle`.
-- Checking the message, not just the boolean, keeps a test honest: it would
-- otherwise pass for the wrong reason the moment an unrelated field broke.
function H.rejects(ok, errs, needle, msg)
  if ok then fail((msg or 'expected rejection') .. ': record was accepted') end
  for _, e in ipairs(errs or {}) do
    if e:lower():find(needle:lower(), 1, true) then return end
  end
  fail(string.format('%s: rejected, but no error mentioned %q. Got: %s',
    msg or 'expected rejection', needle, table.concat(errs or {}, ' | ')))
end

function H.run()
  local pass, failed, total = 0, 0, 0
  local failures = {}
  for _, s in ipairs(H.suites) do
    io.write(YELLOW, '── ', s.name, RESET, '\n')
    for _, c in ipairs(s.cases) do
      total = total + 1
      local ok, err = pcall(c.fn)
      if ok then
        pass = pass + 1
        io.write('   ', GREEN, 'PASS', RESET, '  ', c.name, '\n')
      else
        failed = failed + 1
        local m = type(err) == 'table' and err.__assert and err.msg or tostring(err)
        io.write('   ', RED, 'FAIL', RESET, '  ', c.name, '\n          ', RED, m, RESET, '\n')
        failures[#failures + 1] = s.name .. ' / ' .. c.name .. ': ' .. m
      end
    end
  end
  io.write('\n', string.rep('─', 60), '\n')
  io.write(string.format('%d tests, %s%d passed%s, %s%d failed%s\n',
    total, GREEN, pass, RESET, failed > 0 and RED or GREEN, failed, RESET))
  return failed == 0
end

return H

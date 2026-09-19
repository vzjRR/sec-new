--[[
  tests/unit/test_source_scan.lua

  This module is the engine for EXP-006 (the event inventory) and the canonical Lua
  comment/string stripper for the repository. Both jobs are subtle, and a wrong
  inventory is worse than no inventory: it would silently omit events from contract
  coverage while looking complete.
]]
local H = ...
local S = require('logic.source_scan')

H.suite('source_scan: strip_lua')

H.test('blanks line comments but keeps line structure', function()
  local out = S.strip_lua('local a = 1 -- comment\nlocal b = 2\n')
  H.ok(out:find('local a = 1', 1, true))
  H.is_nil(out:find('comment', 1, true))
  H.eq(select(2, out:gsub('\n', '')), 2, 'line count must be preserved')
end)

H.test('blanks block comments across lines', function()
  local out = S.strip_lua('a\n--[[ hidden\nstill hidden ]]\nb\n')
  H.is_nil(out:find('hidden', 1, true))
  H.ok(out:find('a', 1, true)); H.ok(out:find('b', 1, true))
end)

H.test('blanks string contents', function()
  local out = S.strip_lua([[local s = "DropPlayer(1)"]])
  H.is_nil(out:find('DropPlayer', 1, true))
end)

H.test('a -- inside a string is not a comment', function()
  local out = S.strip_lua([[local s = "a--b" local live = 1]])
  H.ok(out:find('live', 1, true), 'code after the string must survive')
end)

H.test('handles long strings', function()
  local out = S.strip_lua('local s = [[DropPlayer(1)]]\nlocal live = 1\n')
  H.is_nil(out:find('DropPlayer', 1, true))
  H.ok(out:find('live', 1, true))
end)

H.test('byte offsets are preserved so line numbers stay accurate', function()
  local src = '-- c\n--[[ x\ny ]]\nlocal z = 1\n'
  local out = S.strip_lua(src)
  H.eq(#out, #src, 'stripping must not change length')
end)

H.test('tolerates an unterminated comment or string', function()
  H.ok(type(S.strip_lua('--[[ never closed')) == 'string')
  H.ok(type(S.strip_lua('local s = "never closed')) == 'string')
end)

H.test('tolerates a non-string argument', function()
  H.eq(S.strip_lua(nil), '')
  H.eq(S.strip_lua(42), '')
end)

H.suite('source_scan: finding registrations')

H.test('finds a net event with a literal name', function()
  local f = S.scan([[RegisterNetEvent('QBCore:Server:SetMetaData', function() end)]])
  H.eq(#f, 1)
  H.eq(f[1].kind, 'net_event')
  H.eq(f[1].name, 'QBCore:Server:SetMetaData')
  H.eq(f[1].dynamic, false)
end)

H.test('accepts double quotes', function()
  H.eq(S.scan([[RegisterNetEvent("a:b")]])[1].name, 'a:b')
end)

H.test('finds the legacy RegisterServerEvent alias', function()
  local f = S.scan([[RegisterServerEvent('legacy:evt')]])
  H.eq(f[1].kind, 'net_event')
  H.eq(f[1].name, 'legacy:evt')
end)

H.test('classifies AddEventHandler, exports and RegisterCommand', function()
  local f = S.scan(table.concat({
    "AddEventHandler('playerDropped', function() end)",
    "exports('health', function() end)",
    "RegisterCommand('status', function() end)",
  }, '\n'))
  local kinds = {}
  for _, e in ipairs(f) do kinds[e.kind] = e.name end
  H.eq(kinds.event_handler, 'playerDropped')
  H.eq(kinds.export, 'health')
  H.eq(kinds.command, 'status')
end)

H.test('reports a computed name as <dynamic> rather than guessing', function()
  --[[
    Guessing here would put a wrong event name into the contract inventory, which is
    worse than admitting we cannot resolve it: a contract for an event that does not
    exist gives false assurance of coverage.
  ]]
  local f = S.scan([[RegisterNetEvent(prefix .. ':evt')]])
  H.eq(#f, 1)
  H.eq(f[1].name, '<dynamic>')
  H.eq(f[1].dynamic, true)
end)

H.test('records line numbers', function()
  local f = S.scan("local x = 1\n\nRegisterNetEvent('a')\n")
  H.eq(f[1].line, 3)
end)

H.test('finds several registrations on one line', function()
  local f = S.scan([[RegisterNetEvent('a') RegisterNetEvent('b')]])
  H.eq(#f, 2)
end)

H.suite('source_scan: what must NOT be reported')

H.test('a commented-out registration is not live code', function()
  -- Reporting a dead handler would inflate the inventory and waste contract work.
  H.eq(#S.scan("-- RegisterNetEvent('dead:evt')"), 0)
  H.eq(#S.scan("--[[ RegisterNetEvent('dead:evt') ]]"), 0)
end)

H.test('a method call with a matching suffix is not a registration', function()
  H.eq(#S.scan([[thing.RegisterNetEvent('x')]]), 0)
  H.eq(#S.scan([[thing:RegisterNetEvent('x')]]), 0)
end)

H.test('a longer identifier ending in a registrar name is not one', function()
  H.eq(#S.scan([[MyRegisterNetEvent('x')]]), 0)
end)

H.test('the event NAME is kept even though it is a string literal', function()
  -- strip_lua would blank it; the scanner strips comments only, because here the
  -- string literal IS the data.
  H.eq(S.scan([[RegisterNetEvent('keep:me')]])[1].name, 'keep:me')
end)

H.test('an empty or nil source yields nothing', function()
  H.eq(#S.scan(''), 0)
  H.eq(#S.scan(nil), 0)
end)

H.suite('source_scan: inventory')

H.test('merges the same event across resources into one row', function()
  local inv = S.inventory({
    { resource = 'res-a', file = 'server/a.lua',
      entries = S.scan("RegisterNetEvent('shared:evt')") },
    { resource = 'res-b', file = 'server/b.lua',
      entries = S.scan("RegisterNetEvent('shared:evt')") },
  })
  H.eq(#inv, 1)
  H.eq(#inv[1].sites, 2, 'both registration sites must be recorded')
  H.eq(inv[1].sites[1].resource, 'res-a')
end)

H.test('separates rows by kind even for the same name', function()
  local inv = S.inventory({
    { resource = 'r', file = 'f',
      entries = S.scan("RegisterNetEvent('x')\nexports('x', function() end)") },
  })
  H.eq(#inv, 2)
end)

H.test('reports stats including how much was unresolvable', function()
  --[[
    dynamic_n is the honesty number: it says how much of the inventory this lexical
    scan could not resolve, so the result is read as a FLOOR rather than a complete
    list.
  ]]
  local _, stats = S.inventory({
    { resource = 'r1', file = 'a.lua',
      entries = S.scan("RegisterNetEvent('a')\nRegisterNetEvent(x .. 'b')") },
    { resource = 'r2', file = 'b.lua', entries = S.scan("RegisterNetEvent('c')") },
  })
  H.eq(stats.files_n, 2)
  H.eq(stats.entries_n, 3)
  H.eq(stats.dynamic_n, 1)
  H.eq(stats.resources_n, 2)
  H.eq(stats.unique_n, 3)
end)

H.test('an empty inventory is not an error', function()
  local inv, stats = S.inventory({})
  H.eq(#inv, 0); H.eq(stats.files_n, 0); H.eq(stats.resources_n, 0)
  inv, stats = S.inventory(nil)
  H.eq(#inv, 0)
end)

H.test('output ordering is deterministic', function()
  local function build()
    return S.inventory({
      { resource = 'r', file = 'f',
        entries = S.scan("exports('z')\nRegisterNetEvent('a')\nRegisterCommand('m')") },
    })
  end
  local a, b = build(), build()
  for i = 1, #a do H.eq(a[i].kind .. a[i].name, b[i].kind .. b[i].name) end
end)

H.suite('source_scan: realistic QBCore-shaped source')

H.test('scans a handler block like the documented QBCore sample', function()
  local src = [==[
local QBCore = exports['qb-core']:GetCoreObject()

-- this one is commented out
-- RegisterNetEvent('QBCore:Server:Dead')

RegisterNetEvent('QBCore:Server:SetMetaData', function(meta, data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if meta == 'hunger' or meta == 'thirst' then
        if data > 100 then data = 100 end
    end
end)

AddEventHandler('playerDropped', function(reason) end)
]==]
  local f = S.scan(src, { file = 'server/events.lua' })
  local names = {}
  for _, e in ipairs(f) do names[e.name] = e.kind end
  H.eq(names['QBCore:Server:SetMetaData'], 'net_event')
  H.eq(names['playerDropped'], 'event_handler')
  H.is_nil(names['QBCore:Server:Dead'], 'the commented-out one must not appear')
  H.eq(f[1].file, 'server/events.lua', 'the file must be carried through')
end)

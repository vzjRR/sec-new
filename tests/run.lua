--[[
  tests/run.lua -- Tier A entry point.
  Discovers and runs every tests/unit/test_*.lua file.
]]

-- Make the resources' pure logic requireable by its in-resource path.
local TELEMETRY = 'resources/[vzjrr-security]/security-telemetry/'
local CORE      = 'resources/[vzjrr-security]/security-core/'
local FORENSICS = 'resources/[vzjrr-security]/security-forensics/'
local DETECTORS = 'resources/[vzjrr-security]/security-detectors/'
package.path = table.concat({
  TELEMETRY .. '?.lua',
  CORE .. '?.lua',
  FORENSICS .. '?.lua',
  DETECTORS .. '?.lua',
  './?.lua',
  package.path,
}, ';')

local H = require('tests.harness')

local files = {}
local p = io.popen('ls tests/unit/test_*.lua 2>/dev/null')
if p then
  for line in p:lines() do files[#files + 1] = line end
  p:close()
end
table.sort(files)

if #files == 0 then
  io.write('no test files found under tests/unit/\n')
  os.exit(1)
end

for _, f in ipairs(files) do
  local chunk, err = loadfile(f)
  if not chunk then
    io.write('\27[31mLOAD ERROR\27[0m ' .. f .. ': ' .. tostring(err) .. '\n')
    os.exit(1)
  end
  chunk(H)
end

os.exit(H.run() and 0 or 1)

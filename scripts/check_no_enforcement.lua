--[[
  scripts/check_no_enforcement.lua

  Enforces the charter's separation of detection from enforcement (§4, §10, §12)
  and Phase 2's observation-only rule (§18) as a build gate.

  This exists because the temptation is a ONE-LINE change: weaponDamageEvent,
  explosionEvent, entityCreating and playerConnecting are all cancellable, and
  QBCore exposes Kick(). A review can miss a line; a gate cannot.

  Why Lua and not grep: the check must ignore calls named inside COMMENTS (the
  adapters legitimately document that they never cancel events) while still
  catching real calls. That needs actual comment- and string-aware scanning.
  A first attempt with grep silently passed because an unescaped '(' made the
  regex invalid -- which is exactly why this script self-tests before it runs.
]]

local FORBIDDEN = {
  { name = 'CancelEvent',       why = 'Phase 2 is observation only; do not cancel game events' },
  { name = 'DropPlayer',        why = 'enforcement is a separate, future system' },
  { name = 'Kick',              why = 'enforcement is a separate, future system' },
  { name = 'ExecuteCommand',    why = 'can reach ban/kick commands indirectly' },
  { name = 'TriggerClientEvent',why = 'an observatory does not talk to clients' },
  { name = 'AddPermission',     why = 'do not mutate player permissions' },
  { name = 'RemovePermission',  why = 'do not mutate player permissions' },
  { name = 'SetEntityCoords',   why = 'do not mutate game state' },
  { name = 'SetEntityVelocity', why = 'do not mutate game state' },
  { name = 'SetEntityHealth',   why = 'do not mutate game state' },
  { name = 'SetPlayerBucket',   why = 'do not mutate game state' },
  { name = 'SetEntityRotation', why = 'do not mutate game state' },
}

-- lab/ is excluded by only scanning these roots: simulators live in lab/ by design.
local SCAN_ROOTS = { 'resources', 'detectors' }

--[[
  Replace comment AND string-literal bodies with spaces, preserving line structure
  and byte offsets so reported line numbers stay accurate.

  Strings are tracked for two reasons: a '--' inside a string must not be mistaken
  for a comment, and a forbidden name inside a string is not a call. Blanking both
  makes the scan see only real code.
]]
local function strip_comments(src)
  local out, i, n = {}, 1, #src
  local function put(s) out[#out + 1] = s end
  local function blank(s) put((s:gsub('[^\n]', ' '))) end

  while i <= n do
    local c = src:sub(i, i)
    local two = src:sub(i, i + 1)

    if two == '--' then
      -- long comment?
      local lb_eq, lb_end = src:match('^%-%-%[(=*)%[', i)
      if lb_eq then
        local close = ']' .. lb_eq .. ']'
        local stop = src:find(close, i, true)
        local body_end = stop and (stop + #close - 1) or n
        blank(src:sub(i, body_end))
        i = body_end + 1
      else
        local nl = src:find('\n', i, true) or (n + 1)
        blank(src:sub(i, nl - 1))
        i = nl
      end
    elseif c == '"' or c == "'" then
      local q, j = c, i + 1
      while j <= n do
        local ch = src:sub(j, j)
        if ch == '\\' then j = j + 2
        elseif ch == q or ch == '\n' then j = j + 1; break
        else j = j + 1 end
      end
      blank(src:sub(i, j - 1))
      i = j
    else
      local lb_eq = src:match('^%[(=*)%[', i)
      if lb_eq then
        local close = ']' .. lb_eq .. ']'
        local stop = src:find(close, i, true)
        local body_end = stop and (stop + #close - 1) or n
        blank(src:sub(i, body_end))
        i = body_end + 1
      else
        put(c)
        i = i + 1
      end
    end
  end
  return table.concat(out)
end

--- Find forbidden calls in already-stripped source.
-- @return list of { line, name, why, text }
local function find_violations(stripped)
  local hits = {}
  local line_no = 1
  for line in (stripped .. '\n'):gmatch('([^\n]*)\n') do
    for _, rule in ipairs(FORBIDDEN) do
      --[[
        Match both the bare call `Kick(` and the member forms `x.Kick(` / `x:Kick(`.

        The boundary rule differs between them, which is where a first attempt got
        this wrong and missed `QBCore.Functions.Kick(...)`:

          * a member match starts at '.' or ':' -- the character before it belongs
            to the PARENT identifier, so it is always a real call;
          * a bare match must not be preceded by an identifier character, so a
            longer name such as `SoftKick(` is not flagged.

        Every occurrence on the line is scanned, not just the first.
      ]]
      local init = 1
      while true do
        local at, stop = line:find('[%.:]?' .. rule.name .. '%s*%(', init)
        if not at then break end
        local first = line:sub(at, at)
        local is_member = (first == '.' or first == ':')
        local ok
        if is_member then
          ok = true
        else
          local prev = at > 1 and line:sub(at - 1, at - 1) or ''
          ok = not prev:match('[%w_]')
        end
        if ok then
          hits[#hits + 1] = {
            line = line_no, name = rule.name, why = rule.why,
            text = (line:gsub('^%s+', '')),
          }
          break -- one report per rule per line is enough
        end
        init = stop + 1
      end
    end
    line_no = line_no + 1
  end
  return hits
end

-- ---------------------------------------------------------------------------
-- Self test: a guard that cannot fail is worthless.
-- ---------------------------------------------------------------------------
local function self_test()
  local bad = 'local function f(s) DropPlayer(s, "x") CancelEvent() end\n'
  local hits = find_violations(strip_comments(bad))
  if #hits < 2 then
    return false, 'planted violations were not detected (' .. #hits .. ' found)'
  end

  -- Member call forms must be caught. Missing the dot form is the bug this covers.
  for _, form in ipairs({
    'QBCore.Functions.Kick(src, "x")',
    'exports["qb-core"]:Kick(src)',
    'core.Functions.DropPlayer(src)',
    'CancelEvent ()',
  }) do
    if #find_violations(strip_comments(form .. '\n')) == 0 then
      return false, 'missed a forbidden call form: ' .. form
    end
  end

  -- A longer identifier that merely ends with a forbidden name is not a call to it.
  if #find_violations(strip_comments('SoftKick(1)\nMyDropPlayerHelper(2)\n')) > 0 then
    return false, 'flagged a longer identifier that merely ends with a forbidden name'
  end

  local commented = table.concat({
    '-- we never call DropPlayer() here',
    '--[[ and this block explains that CancelEvent() is forbidden ]]',
    'local s = "DropPlayer(x)"  -- a string, not a call',
    'return true',
  }, '\n')
  local ch = find_violations(strip_comments(commented))
  if #ch > 0 then
    return false, 'comment/string prose was wrongly flagged: line '
      .. tostring(ch[1].line) .. ' ' .. tostring(ch[1].name)
  end

  -- Line numbers must survive stripping, so reports point at the real line.
  local numbered = '-- c1\n--[[ multi\nline\ncomment ]]\nDropPlayer(1)\n'
  local nh = find_violations(strip_comments(numbered))
  if #nh ~= 1 or nh[1].line ~= 5 then
    return false, 'line numbers shifted during comment stripping (got '
      .. (nh[1] and nh[1].line or 'none') .. ', expected 5)'
  end
  return true
end

-- ---------------------------------------------------------------------------
local function list_lua_files(root)
  local files = {}
  local p = io.popen(string.format('find %q -name "*.lua" -type f 2>/dev/null | sort', root))
  if not p then return files end
  for line in p:lines() do files[#files + 1] = line end
  p:close()
  return files
end

local function main()
  local ok, err = self_test()
  if not ok then
    io.write('GUARD SELF-TEST FAILED: ', err, '\n')
    io.write('This guard is not trustworthy; fix it before relying on it.\n')
    return 2
  end

  local scanned, violations = 0, {}
  for _, root in ipairs(SCAN_ROOTS) do
    for _, path in ipairs(list_lua_files(root)) do
      local fh = io.open(path, 'r')
      if fh then
        local src = fh:read('a'); fh:close()
        scanned = scanned + 1
        for _, hit in ipairs(find_violations(strip_comments(src))) do
          hit.path = path
          violations[#violations + 1] = hit
        end
      end
    end
  end

  io.write(('no-enforcement guard: %d file(s) scanned, %d pattern(s), self-test passed\n')
    :format(scanned, #FORBIDDEN))

  if #violations == 0 then
    io.write('RESULT: clean -- no enforcement or state-mutating calls found\n')
    return 0
  end

  io.write('\nFORBIDDEN CALLS FOUND:\n')
  for _, v in ipairs(violations) do
    io.write(('  %s:%d  %s()  -- %s\n'):format(v.path, v.line, v.name, v.why))
    io.write(('      %s\n'):format(v.text))
  end
  io.write('\nIf enforcement is genuinely being added, that is a CHARTER change:\n')
  io.write('  1. the incident model must be validated first (charter §12)\n')
  io.write('  2. record the decision in knowledge/decisions/\n')
  io.write('  3. only then amend this guard\n')
  return 1
end

os.exit(main())

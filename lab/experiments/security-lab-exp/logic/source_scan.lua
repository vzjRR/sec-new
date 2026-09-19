--[[
  security-lab-exp / logic / source_scan.lua

  PURE LUA. Scans Lua source text for event registrations and exports.

  This is the engine for EXP-006 (the event inventory). There is no native that
  enumerates registered event handlers, so the only way to build the inventory is to
  read the installed resources' own source -- which `LOAD_RESOURCE_FILE` (shared
  apiset) makes possible.

  It is also the canonical Lua comment/string stripper for this repository:
  `scripts/check_no_enforcement.lua` uses it rather than carrying a second copy.
  Duplicating this parsing is a real hazard -- it is subtle, and a fix to one copy
  would silently not reach the other.

  LIMITS, stated up front. This is a lexical scan, not a Lua parser:
    * a handler registered through a computed name (`RegisterNetEvent(prefix .. n)`)
      is reported as `<dynamic>` rather than guessed at
    * a handler registered by a loop over a table is not resolved
    * generated or escrowed code cannot be read at all
  So the inventory is a FLOOR, never a complete list, and EXP-006's output says so.
  Treating it as complete would mean silently omitting events from contract coverage.
]]

local M = {}

--[[
  Replace comment AND string-literal bodies with spaces, preserving line structure and
  byte offsets so reported line numbers stay accurate.

  Both are blanked: a `--` inside a string is not a comment, and an identifier inside
  a string is not a call.
]]
function M.strip_lua(src)
  if type(src) ~= 'string' then return '' end
  local out, i, n = {}, 1, #src
  local function put(s) out[#out + 1] = s end
  local function blank(s) put((s:gsub('[^\n]', ' '))) end

  while i <= n do
    local c = src:sub(i, i)
    local two = src:sub(i, i + 1)

    if two == '--' then
      local lb_eq = src:match('^%-%-%[(=*)%[', i)
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

--[[
  Find a call's first string argument WITHOUT stripping strings.

  Deliberately separate from strip_lua: here the string literal IS the data we want.
  Comments are still stripped, so a commented-out registration is not reported as a
  live one -- reporting a dead handler would inflate the inventory and waste contract
  work.
]]
local function strip_comments_only(src)
  -- Blank comments by reusing strip_lua on a copy where strings are protected:
  -- simplest correct approach is a second pass that only handles comments.
  local out, i, n = {}, 1, #src
  local function put(s) out[#out + 1] = s end
  local function blank(s) put((s:gsub('[^\n]', ' '))) end

  while i <= n do
    local c = src:sub(i, i)
    local two = src:sub(i, i + 1)
    if two == '--' then
      local lb_eq = src:match('^%-%-%[(=*)%[', i)
      if lb_eq then
        local close = ']' .. lb_eq .. ']'
        local stop = src:find(close, i, true)
        local body_end = stop and (stop + #close - 1) or n
        blank(src:sub(i, body_end)); i = body_end + 1
      else
        local nl = src:find('\n', i, true) or (n + 1)
        blank(src:sub(i, nl - 1)); i = nl
      end
    elseif c == '"' or c == "'" then
      local q, j = c, i + 1
      while j <= n do
        local ch = src:sub(j, j)
        if ch == '\\' then j = j + 2
        elseif ch == q or ch == '\n' then j = j + 1; break
        else j = j + 1 end
      end
      put(src:sub(i, j - 1)); i = j
    else
      put(c); i = i + 1
    end
  end
  return table.concat(out)
end

M.REGISTRARS = {
  RegisterNetEvent    = 'net_event',
  RegisterServerEvent = 'net_event',   -- legacy alias still seen in the wild
  AddEventHandler     = 'event_handler',
  exports             = 'export',
  RegisterCommand     = 'command',
}

--[[
  Scan one file's source.

  @return list of { kind, name, line, dynamic }
]]
function M.scan(src, opts)
  opts = opts or {}
  local cleaned = strip_comments_only(src or '')
  local found = {}

  local line_no = 1
  for line in (cleaned .. '\n'):gmatch('([^\n]*)\n') do
    for fn, kind in pairs(M.REGISTRARS) do
      local init = 1
      while true do
        -- `fn` optionally preceded by nothing (a bare global call).
        local at, stop = line:find(fn .. '%s*%(', init)
        if not at then break end
        local prev = at > 1 and line:sub(at - 1, at - 1) or ''
        if not prev:match('[%w_.:]') then
          -- First argument: a quoted literal, or something computed.
          local rest = line:sub(stop + 1)
          local name = rest:match("^%s*'([^']*)'") or rest:match('^%s*"([^"]*)"')
          found[#found + 1] = {
            kind    = kind,
            name    = name or '<dynamic>',
            dynamic = name == nil,
            line    = line_no,
            file    = opts.file,
          }
        end
        init = stop + 1
      end
    end
    line_no = line_no + 1
  end

  table.sort(found, function(a, b)
    if a.line ~= b.line then return a.line < b.line end
    return tostring(a.name) < tostring(b.name)
  end)
  return found
end

--[[
  Merge per-file scans into an inventory keyed by event name.

  @param scans list of { resource, file, entries }
  @return inventory table, stats table
]]
function M.inventory(scans)
  local by_name, stats = {}, {
    files_n = 0, entries_n = 0, dynamic_n = 0, resources = {},
  }

  for _, s in ipairs(scans or {}) do
    stats.files_n = stats.files_n + 1
    stats.resources[s.resource] = true
    for _, e in ipairs(s.entries or {}) do
      stats.entries_n = stats.entries_n + 1
      if e.dynamic then stats.dynamic_n = stats.dynamic_n + 1 end
      local key = e.kind .. '::' .. e.name
      local row = by_name[key]
      if not row then
        row = { kind = e.kind, name = e.name, dynamic = e.dynamic, sites = {} }
        by_name[key] = row
      end
      row.sites[#row.sites + 1] = {
        resource = s.resource, file = s.file, line = e.line,
      }
    end
  end

  local out = {}
  for _, row in pairs(by_name) do out[#out + 1] = row end
  table.sort(out, function(a, b)
    if a.kind ~= b.kind then return a.kind < b.kind end
    return tostring(a.name) < tostring(b.name)
  end)

  local res = {}
  for r in pairs(stats.resources) do res[#res + 1] = r end
  table.sort(res)
  stats.resources = res
  stats.resources_n = #res
  stats.unique_n = #out

  return out, stats
end

--[[
  DUAL EXPORT -- see docs/ARCHITECTURE.md §3.2 "Module loading".
]]
SecLab = SecLab or {}
SecLab.source_scan = M

return M

--[[
  security-telemetry / logic / jsonl.lua

  PURE LUA. A deterministic JSON encoder and a strict decoder, purpose-built for
  telemetry records.

  ---------------------------------------------------------------------------
  WHY NOT USE FiveM's `json`?

  Two reasons, and the first is the important one.

  1. DETERMINISM. `json.encode` gives no key-order guarantee, because Lua table
     iteration order is unspecified. That makes its output unusable as a regression
     fixture: the same record could serialise two different ways and a byte comparison
     would report a spurious diff. This encoder sorts keys, so a record has exactly
     one serialisation and fixtures are byte-comparable (docs/TESTING_METHODOLOGY.md §1).

  2. AVAILABILITY. The global `json` exists inside FXServer but not under vanilla
     Lua 5.4, which is the only tier that can run unattended (C2). Without a pure
     codec, CI could neither write nor replay an evidence file.

  ---------------------------------------------------------------------------
  DELIBERATE LIMITS

  This is not a general-purpose JSON library and should not grow into one. It handles
  exactly what a TelemetryRecord contains: nested tables of strings, finite numbers,
  booleans, and arrays of those. It REJECTS rather than guesses on anything else --
  NaN, infinity, functions, cycles, mixed array/map tables, non-string keys. A
  security evidence store that silently mangles a value is worse than one that refuses
  to write it.

  KNOWN AMBIGUITY, stated rather than hidden: an empty Lua table is encoded as `{}`
  (object), because the records this serialises use empty tables for `measurements`
  and `context`, which are maps. An empty ARRAY therefore round-trips as `{}` rather
  than `[]`. For our records this is unobservable -- both decode to a table with
  `#t == 0` -- but it is a real asymmetry and code that needs `[]` preserved must not
  use this module.
]]

local M = {}

-- ---------------------------------------------------------------------------
-- Encoding
-- ---------------------------------------------------------------------------

local ESCAPES = {
  ['"']    = '\\"',
  ['\\']   = '\\\\',
  ['\b']   = '\\b',
  ['\f']   = '\\f',
  ['\n']   = '\\n',
  ['\r']   = '\\r',
  ['\t']   = '\\t',
}

local function escape_string(s)
  -- Escape the mandatory characters, then any remaining control character as \uXXXX.
  local out = s:gsub('[%c"\\]', function(c)
    local e = ESCAPES[c]
    if e then return e end
    return string.format('\\u%04x', c:byte())
  end)
  return '"' .. out .. '"'
end

--[[
  Format a number so it round-trips exactly.

  Lua 5.4 distinguishes integer and float subtypes. Integers print exactly with %d.
  Floats need enough significant digits to survive a decode; %.14g is compact and
  usually sufficient, so it is tried first and only escalated when the shorter form
  does not read back identically. Getting this wrong would silently alter a recorded
  measurement, which is the kind of quiet corruption an evidence store must not have.
]]
local function format_number(v)
  if v ~= v then return nil, 'NaN is not representable in JSON' end
  if v == math.huge then return nil, 'infinity is not representable in JSON' end
  if v == -math.huge then return nil, '-infinity is not representable in JSON' end

  if math.type(v) == 'integer' then
    return string.format('%d', v)
  end

  for _, fmt in ipairs({ '%.14g', '%.16g', '%.17g' }) do
    local s = string.format(fmt, v)
    if tonumber(s) == v then
      -- Keep a float looking like a float so the subtype survives a round trip.
      if not s:find('[%.eEn]') then s = s .. '.0' end
      return s
    end
  end
  return nil, 'number could not be formatted losslessly'
end

--- Classify a table as an array or an object. Refuses ambiguity.
local function classify(t)
  local n = #t
  local count, has_string_key = 0, false
  for k in pairs(t) do
    count = count + 1
    if type(k) == 'string' then
      has_string_key = true
    elseif math.type(k) ~= 'integer' then
      return nil, 'table has a key that is neither a string nor an integer'
    end
  end

  if count == 0 then return 'object' end          -- documented choice, see header
  if has_string_key then
    if n > 0 then
      return nil, 'table mixes array and map keys; split it before encoding'
    end
    return 'object'
  end
  if n ~= count then
    return nil, 'sparse array; JSON has no representation for holes'
  end
  return 'array'
end

local encode_value

local function encode_table(t, seen, depth)
  if depth > 32 then return nil, 'nesting deeper than 32 levels' end
  if seen[t] then return nil, 'table contains a cycle' end
  seen[t] = true

  local kind, err = classify(t)
  if not kind then seen[t] = nil; return nil, err end

  local parts = {}
  if kind == 'array' then
    for i = 1, #t do
      local s, e = encode_value(t[i], seen, depth + 1)
      if not s then seen[t] = nil; return nil, string.format('[%d]: %s', i, e) end
      parts[#parts + 1] = s
    end
    seen[t] = nil
    return '[' .. table.concat(parts, ',') .. ']'
  end

  -- Objects: sort keys so the output is deterministic.
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

  for _, k in ipairs(keys) do
    local s, e = encode_value(t[k], seen, depth + 1)
    if not s then seen[t] = nil; return nil, string.format('%s: %s', tostring(k), e) end
    parts[#parts + 1] = escape_string(tostring(k)) .. ':' .. s
  end
  seen[t] = nil
  return '{' .. table.concat(parts, ',') .. '}'
end

encode_value = function(v, seen, depth)
  local ty = type(v)
  if v == nil then return 'null' end
  if ty == 'boolean' then return v and 'true' or 'false' end
  if ty == 'number' then return format_number(v) end
  if ty == 'string' then return escape_string(v) end
  if ty == 'table' then return encode_table(v, seen, depth) end
  return nil, 'cannot encode a value of type ' .. ty
end

--- Encode a value to a single-line JSON string.
-- @return string|nil, err
function M.encode(v)
  return encode_value(v, {}, 0)
end

--- Encode one record as a JSONL line (no trailing newline).
-- Rejects embedded newlines defensively: a newline inside a line would split one
-- record into two unparseable halves and corrupt the whole file from that point on.
function M.encode_line(v)
  local s, err = M.encode(v)
  if not s then return nil, err end
  if s:find('\n', 1, true) then return nil, 'encoded value contains a newline' end
  return s
end

-- ---------------------------------------------------------------------------
-- Decoding
-- ---------------------------------------------------------------------------

local Parser = {}
Parser.__index = Parser

local function new_parser(s)
  return setmetatable({ s = s, i = 1, n = #s }, Parser)
end

function Parser:error(msg)
  return nil, string.format('%s at byte %d', msg, self.i)
end

function Parser:skip_ws()
  local i = self.s:find('[^ \t\n\r]', self.i)
  self.i = i or (self.n + 1)
end

function Parser:peek() return self.s:sub(self.i, self.i) end

function Parser:literal(word, value)
  if self.s:sub(self.i, self.i + #word - 1) == word then
    self.i = self.i + #word
    return true, value
  end
  return false
end

local UNESCAPES = {
  ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
  b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
}

function Parser:parse_string()
  if self:peek() ~= '"' then return self:error('expected a string') end
  self.i = self.i + 1
  local parts = {}
  while true do
    if self.i > self.n then return self:error('unterminated string') end
    local c = self.s:sub(self.i, self.i)
    if c == '"' then
      self.i = self.i + 1
      return table.concat(parts)
    elseif c == '\\' then
      local e = self.s:sub(self.i + 1, self.i + 1)
      local u = UNESCAPES[e]
      if u then
        parts[#parts + 1] = u
        self.i = self.i + 2
      elseif e == 'u' then
        local hex = self.s:sub(self.i + 2, self.i + 5)
        if not hex:match('^%x%x%x%x$') then return self:error('bad \\u escape') end
        local cp = tonumber(hex, 16)
        -- Records hold ASCII identifiers and enums; a surrogate pair would mean the
        -- data is not what this module is for, so it is refused rather than mangled.
        if cp >= 0xD800 and cp <= 0xDFFF then
          return self:error('surrogate pair escapes are not supported')
        end
        parts[#parts + 1] = utf8.char(cp)
        self.i = self.i + 6
      else
        return self:error('invalid escape sequence')
      end
    elseif c:byte() < 0x20 then
      return self:error('raw control character in string')
    else
      parts[#parts + 1] = c
      self.i = self.i + 1
    end
  end
end

function Parser:parse_number()
  local pattern = '^-?%d+%.?%d*[eE]?[-+]?%d*'
  local text = self.s:match(pattern, self.i)
  if not text or text == '' then return self:error('expected a number') end
  local v = tonumber(text)
  if v == nil then return self:error('malformed number') end
  self.i = self.i + #text
  -- Preserve the integer/float distinction: a value written as "35" comes back as an
  -- integer, "35.0" as a float, so a round trip does not change math.type().
  if not text:find('[%.eE]') then
    local asint = math.tointeger(v)
    if asint then v = asint end
  else
    v = v + 0.0
  end
  return v
end

local parse_value

function Parser:parse_array()
  self.i = self.i + 1 -- '['
  local out = {}
  self:skip_ws()
  if self:peek() == ']' then self.i = self.i + 1; return out end
  while true do
    self:skip_ws()
    local v, err = parse_value(self)
    if err then return nil, err end
    out[#out + 1] = v
    self:skip_ws()
    local c = self:peek()
    if c == ',' then
      self.i = self.i + 1
    elseif c == ']' then
      self.i = self.i + 1
      return out
    else
      return self:error('expected "," or "]" in array')
    end
  end
end

function Parser:parse_object()
  self.i = self.i + 1 -- '{'
  local out = {}
  self:skip_ws()
  if self:peek() == '}' then self.i = self.i + 1; return out end
  while true do
    self:skip_ws()
    local k, err = self:parse_string()
    if err then return nil, err end
    self:skip_ws()
    if self:peek() ~= ':' then return self:error('expected ":" after object key') end
    self.i = self.i + 1
    self:skip_ws()
    local v, verr = parse_value(self)
    if verr then return nil, verr end
    out[k] = v
    self:skip_ws()
    local c = self:peek()
    if c == ',' then
      self.i = self.i + 1
    elseif c == '}' then
      self.i = self.i + 1
      return out
    else
      return self:error('expected "," or "}" in object')
    end
  end
end

parse_value = function(p)
  local c = p:peek()
  if c == '' then return p:error('unexpected end of input') end
  if c == '{' then return p:parse_object() end
  if c == '[' then return p:parse_array() end
  if c == '"' then return p:parse_string() end
  if c == '-' or c:match('%d') then return p:parse_number() end

  local ok, v = p:literal('true', true);  if ok then return v end
  ok, v = p:literal('false', false);      if ok then return v end
  -- `null` becomes a sentinel rather than nil, because nil in a table is
  -- indistinguishable from an absent key and would silently drop the field.
  ok = p:literal('null', nil)
  if ok then return M.NULL end

  return p:error('unexpected character ' .. string.format('%q', c))
end

--- Sentinel for JSON null. Distinct from nil so a present-but-null field is visible.
M.NULL = setmetatable({}, { __tostring = function() return 'json.NULL' end })

--- Decode a JSON string. Strict: trailing content is an error.
-- @return value, nil | nil, err
function M.decode(s)
  if type(s) ~= 'string' then return nil, 'decode expects a string' end
  local p = new_parser(s)
  p:skip_ws()
  local v, err = parse_value(p)
  if err then return nil, err end
  p:skip_ws()
  if p.i <= p.n then
    return nil, string.format('trailing content at byte %d', p.i)
  end
  return v
end

--[[
  Decode a JSONL body into a list of values.

  Per-line error isolation is deliberate: one corrupt line in an evidence file must
  not discard the whole file. Corrupt lines are reported with their line numbers so
  the loss is visible -- the same principle as the timeline surfacing gaps rather
  than hiding them.

  @return records table, errors table  (errors: { {line, err, text} })
]]
function M.decode_lines(body)
  local records, errors = {}, {}
  if type(body) ~= 'string' then return records, { { line = 0, err = 'body is not a string' } } end
  local line_no = 0
  for line in (body .. '\n'):gmatch('([^\n]*)\n') do
    line_no = line_no + 1
    if line:match('^%s*$') == nil then
      local v, err = M.decode(line)
      if err then
        errors[#errors + 1] = { line = line_no, err = err, text = line:sub(1, 120) }
      else
        records[#records + 1] = v
      end
    end
  end
  return records, errors
end

--[[
  DUAL EXPORT -- see docs/ARCHITECTURE.md §3.2 "Module loading".

  FiveM has no documented `require` for resource scripts: every file listed in
  `server_scripts` is loaded as a plain chunk into one shared Lua state, and the
  chunk's return value is DISCARDED. Publishing to a single resource-scoped global
  satisfies both that and vanilla Lua's return-value convention.
]]
SecLab = SecLab or {}
SecLab.jsonl = M

return M

--[[
  security-telemetry / sinks / jsonl.lua

  ADAPTER. Append-only JSON Lines, one file per category per UTC day
  (docs/TELEMETRY_SCHEMA.md §8).

  Append-only is a forensic choice as much as a performance one: records are
  write-once, so the evidence store is tamper-evident, cheap on the hot path,
  naturally ordered, and directly replayable as a CI fixture.

  Writes go through the resource's own directory via io.open. FXServer runs the
  server-side Lua with standard library access, so io is available -- but this is
  UNVERIFIED on the target build and is one of the things Tier B must confirm
  (see docs/TESTING_METHODOLOGY.md, EXP-008).
]]
local M = {}

local function day_stamp()
  return os.date('!%Y-%m-%d')
end

function M.new(opts)
  opts = opts or {}
  local root = opts.root or 'telemetry'
  local handles, written, errors = {}, 0, 0

  local function path_for(category)
    return string.format('%s/%s/%s.jsonl', root, day_stamp(), category)
  end

  local function handle_for(category)
    local p = path_for(category)
    local h = handles[p]
    if h then return h end
    -- Directory creation is deliberately the operator's job: a security resource
    -- should not be issuing shell commands. If the directory is missing we report
    -- it rather than silently discarding evidence.
    local fh, err = io.open(p, 'a')
    if not fh then
      errors = errors + 1
      return nil, err
    end
    handles[p] = fh
    return fh
  end

  return {
    name = 'jsonl',
    write = function(rec)
      local ok, encoded = pcall(json.encode, rec)
      if not ok then errors = errors + 1; return false, 'encode failed' end
      local fh, err = handle_for(rec.category or 'unknown')
      if not fh then return false, err end
      fh:write(encoded, '\n')
      written = written + 1
      return true
    end,
    flush = function()
      for _, fh in pairs(handles) do pcall(function() fh:flush() end) end
      return true
    end,
    close = function()
      for p, fh in pairs(handles) do pcall(function() fh:close() end); handles[p] = nil end
    end,
    stats = function() return { written_n = written, errors_n = errors } end,
  }
end


--[[
  DUAL EXPORT -- see docs/ARCHITECTURE.md §3.2 "Module loading".

  FiveM has no documented `require` for resource scripts: every file listed in
  `server_scripts` is loaded as a plain chunk into one shared Lua state, and the
  chunk's return value is DISCARDED. So returning the table is not enough to make
  this module reachable inside FXServer.

  Vanilla Lua 5.4 (the CI tier) is the opposite: it uses the return value and has
  no shared namespace.

  Publishing to a single resource-scoped global satisfies both without an
  environment check. Each resource gets its own Lua state, so `SecLab` does not
  leak between resources.
]]
SecLab = SecLab or {}
SecLab.sink_jsonl = M

return M

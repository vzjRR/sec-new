--[[
  security-forensics / sinks / file.lua

  ADAPTER. An append-only file backend for the evidence store.

  UNVERIFIED (EXP-008): whether `io.open` in append mode is available to server-side
  Lua on the target FXServer build, and what the resource's working directory is.
  This is written against the standard Lua library and MUST be confirmed on the lab.
  If `io` turns out to be restricted, the store's injected-backend design means only
  this file changes -- swap in a KVP-batching or HTTP-shipping backend instead.

  Directory creation is deliberately NOT attempted: a security resource should not be
  issuing shell commands. A missing directory surfaces as a counted backend failure,
  which the store already reports, rather than being papered over.
]]
local M = {}

function M.new(opts)
  opts = opts or {}
  local handles = {}
  local opened_n, failed_n = 0, 0

  return {
    name = 'file',

    append = function(path, line)
      local fh = handles[path]
      if not fh then
        local h, err = io.open(path, 'a')
        if not h then
          failed_n = failed_n + 1
          return false, string.format('cannot open %s: %s', path, tostring(err))
        end
        handles[path] = h
        opened_n = opened_n + 1
        fh = h
      end
      local ok, err = pcall(function()
        fh:write(line, '\n')
        -- Flush per line: an unflushed buffer lost to a crash is lost evidence, and
        -- a crash is exactly when the last records matter most.
        fh:flush()
      end)
      if not ok then
        failed_n = failed_n + 1
        return false, tostring(err)
      end
      return true
    end,

    read = function(path)
      local fh, err = io.open(path, 'r')
      if not fh then return nil, tostring(err) end
      local body = fh:read('a')
      fh:close()
      return body
    end,

    close = function()
      for p, fh in pairs(handles) do
        pcall(function() fh:close() end)
        handles[p] = nil
      end
    end,

    stats = function() return { opened_n = opened_n, failed_n = failed_n } end,
  }
end

SecLab = SecLab or {}
SecLab.sink_file = M

return M

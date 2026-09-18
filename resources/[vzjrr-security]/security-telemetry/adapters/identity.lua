--[[
  security-telemetry / adapters / identity.lua

  ADAPTER. Maps a transient FiveM `source` to a durable player_key.

  QBCore integration is deliberately defensive (docs/QBCORE_INTEGRATION.md §1):

  * We use the DOCUMENTED export `exports['qb-core']:GetPlayer(source)` rather than
    importing the whole core object.
  * The official QBCore docs describe only a CLIENT-side `QBCore:Client:OnPlayerLoaded`.
    There is no documented SERVER-side player-loaded event, so we do NOT listen for
    one -- inventing an event name would violate charter §20. We resolve lazily with
    a bounded retry instead.
  * Every call is wrapped in pcall. If qb-core is missing, stopped or older than
    1.3.0, enrichment is disabled and the session stays SRC-keyed. Core telemetry
    never depended on QBCore.
]]
local M = {}

local sessions = {}   -- [src] = { player_key, citizenid, joined_mono, resolved }
local framework_state = { available = nil, note = nil }

local function src_key(src) return 'SRC:' .. tostring(src) end

--- Try the documented QBCore export. Returns PlayerData or nil.
local function try_qbcore_player(src)
  local ok, result = pcall(function()
    local exp = exports['qb-core']
    if not exp then return nil end
    local player = exp:GetPlayer(src)
    if not player then return nil end
    return player.PlayerData
  end)
  if not ok then
    if framework_state.available ~= false then
      framework_state.available = false
      framework_state.note = 'qb-core export unavailable: ' .. tostring(result)
    end
    return nil
  end
  if result then framework_state.available = true end
  return result
end

--- citizenid must be safe to embed in a player_key (schema restricts the charset).
local function sanitize_citizenid(cid)
  if type(cid) ~= 'string' then return nil end
  if cid == '' or #cid > 64 then return nil end
  if cid:match('^[%w_-]+$') then return cid end
  return nil
end

function M.begin_session(src, mono_now)
  sessions[src] = {
    player_key  = src_key(src),
    citizenid   = nil,
    joined_mono = mono_now,
    resolved    = false,
  }
  return sessions[src].player_key
end

function M.end_session(src)
  local s = sessions[src]
  sessions[src] = nil
  return s
end

--- Current key for a source. Always returns something usable.
function M.key_for(src)
  local s = sessions[src]
  if s then return s.player_key, s.resolved end
  return src_key(src), false
end

--[[
  Attempt to upgrade a SRC: key to a QB: key.
  @return upgraded boolean, player_key string, previous_key string|nil
]]
function M.try_resolve(src, enabled)
  local s = sessions[src]
  if not s or s.resolved then return false, s and s.player_key or src_key(src), nil end
  if not enabled then return false, s.player_key, nil end

  local data = try_qbcore_player(src)
  if not data then return false, s.player_key, nil end

  local cid = sanitize_citizenid(data.citizenid)
  if not cid then return false, s.player_key, nil end

  local previous = s.player_key
  s.citizenid = cid
  s.player_key = 'QB:' .. cid
  s.resolved = true
  return true, s.player_key, previous
end

--[[
  Framework context safe to attach to telemetry.
  Deliberately omits charinfo entirely -- names, birthdate, phone and account number
  have no detection value and real privacy cost (docs/QBCORE_INTEGRATION.md §2).
]]
function M.framework_context(src, enabled)
  if not enabled then return nil end
  local data = try_qbcore_player(src)
  if not data then return nil end

  local job, gang = data.job or {}, data.gang or {}
  local meta = data.metadata or {}
  return {
    job_name     = type(job.name) == 'string' and job.name or nil,
    job_grade    = type(job.grade) == 'table' and tonumber(job.grade.level) or nil,
    job_onduty   = job.onduty and true or false,
    job_isboss   = job.isboss and true or false,
    gang_name    = type(gang.name) == 'string' and gang.name or nil,
    is_dead      = meta.isdead and true or false,
    cid          = tonumber(data.cid),
  }
end

function M.framework_status()
  return {
    available = framework_state.available,
    note      = framework_state.note,
  }
end

function M.active_sessions() return sessions end

return M

--[[
  security-telemetry / adapters / events.lua

  ADAPTER. Subscribes to FiveM's server-side events and hands plain tables to the
  pure normalizers.

  OBSERVATION ONLY. Every event below is documented as cancellable, and this file
  deliberately never calls CancelEvent(). Detection and enforcement are separate
  systems (charter §10, §12); see scripts/check-no-enforcement.sh, which fails the
  build if a cancellation or kick appears here.

  Event names and payload fields follow the official server-events reference.
]]
local M = {}

--- @param deps { normalize, builder, identity, emit=function(record), config, log }
function M.install(deps)
  local normalize = deps.normalize
  local identity  = deps.identity
  local emit      = deps.emit
  local cfg       = deps.config
  local log       = deps.log
  local builder   = deps.builder
  local mono      = deps.mono
  local qb        = cfg['framework.qbcore']

  local function key(src) return (identity.key_for(src)) end

  -- ---------------- combat ----------------

  -- weaponDamageEvent(sender, data) -- payload is a CLIENT CLAIM (trust: claimed)
  AddEventHandler('weaponDamageEvent', function(sender, data)
    local ok, err = pcall(function()
      emit(normalize.weapon_damage(builder, key(sender), sender, data))
    end)
    if not ok then log:error('weaponDamageEvent adapter failed', { err = tostring(err) }) end
  end)

  -- explosionEvent(sender, data) -- requires OneSync
  AddEventHandler('explosionEvent', function(sender, data)
    local ok, err = pcall(function()
      emit(normalize.explosion(builder, key(sender), sender, data))
    end)
    if not ok then log:error('explosionEvent adapter failed', { err = tostring(err) }) end
  end)

  -- ---------------- entities ----------------

  --- Resolve an entity handle into server-observed facts.
  local function resolve_entity(handle)
    local resolved = { handle = handle }
    pcall(function()
      resolved.entity_type     = GetEntityType(handle)
      resolved.model           = GetEntityModel(handle)
      resolved.population_type = GetEntityPopulationType(handle)
      resolved.bucket          = GetEntityRoutingBucket(handle)
      local script             = GetEntityScript(handle)
      resolved.script          = (type(script) == 'string' and script ~= '') and script or nil
    end)
    return resolved
  end

  local function entity_handler(phase)
    return function(handle)
      local ok, err = pcall(function()
        local resolved = resolve_entity(handle)
        -- entityCreating/-Created carry no owner; NetworkGetEntityOwner is client-side,
        -- so owner attribution is left nil rather than guessed (charter §20).
        emit(normalize.entity_lifecycle(builder, 'SYSTEM', nil, phase, resolved))
      end)
      if not ok then
        log:error('entity adapter failed', { phase = phase, err = tostring(err) })
      end
    end
  end

  AddEventHandler('entityCreating', entity_handler('creating'))
  AddEventHandler('entityCreated',  entity_handler('created'))
  AddEventHandler('entityRemoved',  entity_handler('removed'))

  -- ---------------- player lifecycle ----------------

  -- playerJoining(source, oldID) -- the player now has a final NetID
  AddEventHandler('playerJoining', function(oldID)
    local src = source
    local ok, err = pcall(function()
      identity.begin_session(src, mono())
      emit(normalize.player_lifecycle(builder, key(src), src, 'player_joining',
        { old_src = tonumber(oldID), source_event = 'playerJoining' }))

      -- Resolve the QBCore citizenid with a bounded retry. There is no documented
      -- server-side player-loaded event, so we poll rather than guess an event name.
      CreateThread(function()
        local deadline = mono() + (cfg['framework.resolve_timeout_ms'] or 60000)
        while mono() < deadline do
          Wait(cfg['framework.resolve_retry_ms'] or 2000)
          if not identity.active_sessions()[src] then return end
          local upgraded, new_key, previous = identity.try_resolve(src, qb)
          if upgraded then
            -- Forensics records the rebinding explicitly rather than rewriting
            -- history (docs/TELEMETRY_SCHEMA.md §2).
            emit(normalize.player_lifecycle(builder, new_key, src, 'identity_resolved',
              { source_event = 'playerJoining', reason = previous }))
            return
          end
        end
      end)
    end)
    if not ok then log:error('playerJoining adapter failed', { err = tostring(err) }) end
  end)

  AddEventHandler('playerDropped', function(reason)
    local src = source
    local ok, err = pcall(function()
      local k = key(src)
      local session = identity.end_session(src)
      emit(normalize.player_lifecycle(builder, k, src, 'player_dropped', {
        reason = type(reason) == 'string' and reason:sub(1, 128) or nil,
        session_ms = session and session.joined_mono and (mono() - session.joined_mono) or nil,
        source_event = 'playerDropped',
      }))
    end)
    if not ok then log:error('playerDropped adapter failed', { err = tostring(err) }) end
  end)

  AddEventHandler('playerEnteredScope', function(data)
    pcall(function()
      local for_src = tonumber(data and data['for'])
      local peer    = tonumber(data and data.player)
      if not for_src then return end
      emit(normalize.player_lifecycle(builder, key(for_src), for_src, 'scope_entered',
        { peer_src = peer, source_event = 'playerEnteredScope' }))
    end)
  end)

  AddEventHandler('playerLeftScope', function(data)
    pcall(function()
      local for_src = tonumber(data and data['for'])
      local peer    = tonumber(data and data.player)
      if not for_src then return end
      emit(normalize.player_lifecycle(builder, key(for_src), for_src, 'scope_left',
        { peer_src = peer, source_event = 'playerLeftScope' }))
    end)
  end)

  AddEventHandler('onPlayerBucketChange', function(src, bucket)
    pcall(function()
      local s = tonumber(src)
      if not s then return end
      emit(normalize.player_lifecycle(builder, key(s), s, 'bucket_changed',
        { bucket = tonumber(bucket), source_event = 'onPlayerBucketChange' }))
    end)
  end)

  log:info('event adapters installed', { count_n = 10 })
end

return M

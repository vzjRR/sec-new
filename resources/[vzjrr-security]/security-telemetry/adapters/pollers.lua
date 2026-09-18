--[[
  security-telemetry / adapters / pollers.lua

  ADAPTER. Samples state that has no event, using only natives verified as
  server-callable in docs/ENVIRONMENT_AUDIT.md §7.

  charter §15: prefer event-driven signals, and where polling is unavoidable use the
  lowest frequency that still supports the signal. Each poller states its cost
  reasoning. Every interval is config-bounded, so a mistyped value cannot busy-loop
  a live game server.
]]
local M = {}

-- GET_PLAYER_PEER_STATISTICS enum, documented (audit §7.5).
local PEER = {
  PacketLoss = 0, PacketLossVariance = 1, PacketLossEpoch = 2,
  RoundTripTime = 3, RoundTripTimeVariance = 4,
}

local function players()
  -- Under OneSync Infinity all player iteration must happen server-side (audit §7.8).
  local ok, list = pcall(GetPlayers)
  if ok and type(list) == 'table' then return list end
  return {}
end

local function vec_xyz(v)
  if type(v) == 'table' then return v.x or v[1], v.y or v[2], v.z or v[3] end
  -- CfxLua vector3 exposes .x/.y/.z; a pcall keeps a surprising shape from crashing us.
  local ok, x, y, z = pcall(function() return v.x, v.y, v.z end)
  if ok then return x, y, z end
  return nil, nil, nil
end

function M.install(deps)
  local normalize = deps.normalize
  local identity  = deps.identity
  local emit      = deps.emit
  local cfg       = deps.config
  local log       = deps.log
  local builder   = deps.builder

  -- ------------------------------------------------------------------
  -- Movement. 1s default: frequent enough to see a teleport, cheap enough
  -- to run per-player. Cannot see between samples -- a documented limitation
  -- (docs/ARCHITECTURE.md §10.6).
  -- ------------------------------------------------------------------
  CreateThread(function()
    while true do
      Wait(cfg['poll.movement_ms'])
      for _, id in ipairs(players()) do
        local src = tonumber(id)
        if src then
          pcall(function()
            local ped = GetPlayerPed(src)
            if not ped or ped == 0 then return end
            local px, py, pz = vec_xyz(GetEntityCoords(ped))
            local vx, vy, vz = vec_xyz(GetEntityVelocity(ped))
            local veh = GetVehiclePedIsIn(ped)
            emit(normalize.movement_sample(builder, (identity.key_for(src)), src, {
              x = px, y = py, z = pz,
              vx = vx, vy = vy, vz = vz,
              speed      = GetEntitySpeed(ped),
              heading    = GetEntityHeading(ped),
              in_vehicle = veh ~= nil and veh ~= 0,
              vehicle_model = (veh and veh ~= 0) and GetEntityModel(veh) or nil,
              bucket     = GetPlayerRoutingBucket(src),
              is_ragdoll = IsPedRagdoll(ped),
            }))
          end)
        end
      end
    end
  end)

  -- ------------------------------------------------------------------
  -- Network. 10s default because peer statistics only refresh every 10s
  -- server-side (audit §7.5). Polling faster would burn CPU for identical data.
  -- ------------------------------------------------------------------
  CreateThread(function()
    while true do
      Wait(cfg['poll.network_ms'])
      for _, id in ipairs(players()) do
        local src = tonumber(id)
        if src then
          pcall(function()
            local s = tostring(src)
            emit(normalize.network_sample(builder, (identity.key_for(src)), src, {
              ping_ms              = GetPlayerPing(s),
              last_msg_ms          = GetPlayerLastMsg(s),
              rtt_ms               = GetPlayerPeerStatistics(s, PEER.RoundTripTime),
              rtt_variance_ms      = GetPlayerPeerStatistics(s, PEER.RoundTripTimeVariance),
              packet_loss_raw      = GetPlayerPeerStatistics(s, PEER.PacketLoss),
              packet_loss_variance = GetPlayerPeerStatistics(s, PEER.PacketLossVariance),
              packet_loss_epoch_ms = GetPlayerPeerStatistics(s, PEER.PacketLossEpoch),
            }))
          end)
        end
      end
    end
  end)

  -- ------------------------------------------------------------------
  -- Aim / camera. RECORDING ONLY.
  --
  -- GET_PLAYER_CAMERA_ROTATION is a genuine server native (audit §7.2), but its
  -- update rate and precision are UNMEASURED (EXP-001). The 500ms default is a
  -- placeholder chosen to gather data for that experiment, NOT a tuned value, and
  -- no detector consumes these records yet. charter §21 forbids turning an
  -- untested hypothesis into a detection rule.
  -- ------------------------------------------------------------------
  CreateThread(function()
    while true do
      Wait(cfg['poll.aim_ms'])
      for _, id in ipairs(players()) do
        local src = tonumber(id)
        if src then
          pcall(function()
            local s = tostring(src)
            local ped = GetPlayerPed(src)
            if not ped or ped == 0 then return end
            local rx, ry, rz = vec_xyz(GetPlayerCameraRotation(s))
            local fx, fy, fz = vec_xyz(GetPlayerFocusPos(s))
            local veh = GetVehiclePedIsIn(ped)
            emit(normalize.aim_sample(builder, (identity.key_for(src)), src, {
              pitch = rx, yaw = rz, roll = ry,
              focus_x = fx, focus_y = fy, focus_z = fz,
              free_cam = IsPlayerInFreeCamMode(s),
              weapon_hash = GetSelectedPedWeapon(ped),
              in_vehicle = veh ~= nil and veh ~= 0,
            }))
          end)
        end
      end
    end
  end)

  log:info('pollers installed', {
    movement_ms = cfg['poll.movement_ms'],
    network_ms  = cfg['poll.network_ms'],
    aim_ms      = cfg['poll.aim_ms'],
  })
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
SecLab.pollers = M

return M

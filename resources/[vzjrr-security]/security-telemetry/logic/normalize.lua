--[[
  security-telemetry / logic / normalize.lua

  PURE LUA. Converts raw FiveM event payloads and polled samples into
  TelemetryRecords. No natives here: adapters read the world and pass plain tables,
  which is what makes this layer unit-testable in CI (docs/ARCHITECTURE.md §2 C2).

  ---------------------------------------------------------------------------
  A DELIBERATE DESIGN CHOICE, worth reading before adding a normalizer:

  A record carries exactly ONE `trust` value (docs/TELEMETRY_SCHEMA.md §6). So a
  normalizer never mixes a client's claim with a server observation in the same
  record -- for example it does NOT fold server-observed shooter/target coordinates
  into a weaponDamageEvent record to compute a "real" distance.

  Instead, claimed and observed records are emitted separately and joined by
  `correlation_id`. A detector that wants to compare "claimed hit" against
  "observed geometry" reads both. This keeps provenance unambiguous, and it means
  no detector can be tricked into treating a fabricated payload as a measurement
  the server vouched for.
  ---------------------------------------------------------------------------
]]

local M = {}

-- Documented in the GET_PLAYER_PEER_STATISTICS reference (audit §7.5).
M.ENET_PACKET_LOSS_SCALE = 65536

local function num(v)
  if type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge then return v end
  return nil
end

local function boolean_of(v)
  if v == nil then return nil end
  return v and true or false
end

--- Convert a raw ENet packet-loss figure to a percentage.
-- The 65536 scale is a documented constant and an easy thing to forget; getting it
-- wrong by that factor would make every player look like they had catastrophic loss,
-- which would suppress real detections rather than cause false ones -- still bad.
function M.packet_loss_pct(raw)
  local r = num(raw)
  if not r then return nil end
  return (r / M.ENET_PACKET_LOSS_SCALE) * 100.0
end

--[[
  weaponDamageEvent -> combat record, trust = 'claimed'.

  Field names follow the official server-events reference. Nothing is inferred:
  `damageTime` is recorded with a dimensionless `_n` suffix rather than `_ms`
  because its clock base and unit are NOT documented (audit §7.3, EXP-002).
  Labelling it `_n` records our uncertainty in the data itself, so no detector can
  silently treat it as milliseconds before the experiment has been run.
]]
function M.weapon_damage(builder, player_key, src, data, opts)
  data = data or {}
  opts = opts or {}

  local hit_ids = data.hitGlobalIds
  local hit_count = 0
  if type(hit_ids) == 'table' then
    hit_count = #hit_ids
  elseif num(data.hitGlobalId) and data.hitGlobalId ~= 0 then
    hit_count = 1
  end

  local m = {
    claimed_damage_n      = num(data.weaponDamage),
    claimed_hit_targets_n = hit_count,
    claimed_damage_time_n = num(data.damageTime), -- unit unknown: see EXP-002
    claimed_local_pos_x_m = num(data.localPosX),
    claimed_local_pos_y_m = num(data.localPosY),
    claimed_local_pos_z_m = num(data.localPosZ),
  }

  return builder:build{
    player_key   = player_key,
    src          = src,
    category     = 'combat',
    event        = 'weapon_damage',
    source       = 'event:weaponDamageEvent',
    trust        = 'claimed',
    measurements = m,
    context      = {
      weapon_hash      = num(data.weaponType),
      damage_type      = num(data.damageType),
      damage_flags     = num(data.damageFlags),
      hit_component    = num(data.hitComponent),
      hit_global_id    = num(data.hitGlobalId),
      parent_global_id = num(data.parentGlobalId),
      will_kill        = boolean_of(data.willKill),
      silenced         = boolean_of(data.silenced),
      override_damage  = boolean_of(data.overrideDefaultDamage),
      has_vehicle_data = boolean_of(data.hasVehicleData),
      net_target_pos   = boolean_of(data.isNetTargetPos),
      target_key       = opts.target_key,
    },
    correlation_id = opts.correlation_id,
  }
end

--- explosionEvent -> combat record, trust = 'claimed'.
function M.explosion(builder, player_key, src, data, opts)
  data = data or {}
  opts = opts or {}
  return builder:build{
    player_key   = player_key,
    src          = src,
    category     = 'combat',
    event        = 'explosion',
    source       = 'event:explosionEvent',
    trust        = 'claimed',
    measurements = {
      claimed_pos_x_m        = num(data.posX),
      claimed_pos_y_m        = num(data.posY),
      claimed_pos_z_m        = num(data.posZ),
      claimed_damage_scale_n = num(data.damageScale),
      claimed_camera_shake_n = num(data.cameraShake),
    },
    context = {
      explosion_type = num(data.explosionType),
      owner_net_id   = num(data.ownerNetId),
      is_audible     = boolean_of(data.isAudible),
      is_invisible   = boolean_of(data.isInvisible),
    },
    correlation_id = opts.correlation_id,
  }
end

--[[
  entityCreating / entityCreated -> entity record, trust = 'observed'.

  The event itself only carries a handle; the adapter resolves model, type,
  population type and owner through server natives, so the resulting record is a
  server observation rather than a client claim.
]]
function M.entity_lifecycle(builder, player_key, src, phase, resolved, opts)
  resolved = resolved or {}
  opts = opts or {}
  return builder:build{
    player_key   = player_key,
    src          = src,
    category     = 'entity',
    event        = 'entity_' .. phase,
    source        = 'event:entity' .. (phase == 'creating' and 'Creating'
                      or phase == 'created' and 'Created' or 'Removed'),
    trust        = 'observed',
    measurements = {
      handle_n = num(resolved.handle),
    },
    context = {
      entity_type     = num(resolved.entity_type),
      model_hash      = num(resolved.model),
      population_type = num(resolved.population_type),
      owner_src       = num(resolved.owner_src),
      script          = resolved.script,
      bucket          = num(resolved.bucket),
    },
    correlation_id = opts.correlation_id,
  }
end

--- Player lifecycle. trust = 'observed' (the server owns these transitions).
function M.player_lifecycle(builder, player_key, src, event, details, opts)
  details = details or {}
  opts = opts or {}
  return builder:build{
    player_key   = player_key,
    src          = src,
    category     = 'player_state',
    event        = event, -- 'player_joining' | 'player_dropped' | 'scope_entered' | ...
    source       = 'event:' .. (details.source_event or event),
    trust        = 'observed',
    measurements = {
      session_ms = num(details.session_ms),
    },
    context = {
      reason    = details.reason,
      old_src   = num(details.old_src),
      peer_src  = num(details.peer_src),
      bucket    = num(details.bucket),
    },
    correlation_id = opts.correlation_id,
  }
end

--[[
  Network quality sample -> network record, trust = 'observed'.

  Peer statistics refresh only once per 10 seconds server-side (audit §7.5), so
  `stale_ms` is carried explicitly. A detector must be able to tell "loss was 0%"
  from "loss was last measured 9 seconds ago", or it will treat stale good news as
  evidence that an anomaly had no network explanation.
]]
function M.network_sample(builder, player_key, src, sample, opts)
  sample = sample or {}
  opts = opts or {}
  return builder:build{
    player_key   = player_key,
    src          = src,
    category     = 'network',
    event        = 'network_sample',
    source       = 'poll:peer_statistics',
    trust        = 'observed',
    measurements = {
      ping_ms            = num(sample.ping_ms),
      rtt_ms             = num(sample.rtt_ms),
      rtt_variance_ms    = num(sample.rtt_variance_ms),
      packet_loss_pct    = M.packet_loss_pct(sample.packet_loss_raw),
      packet_loss_var_n  = num(sample.packet_loss_variance),
      stale_ms           = num(sample.packet_loss_epoch_ms),
      last_msg_ms        = num(sample.last_msg_ms),
    },
    context = {},
    correlation_id = opts.correlation_id,
  }
end

--- Movement sample -> movement record, trust = 'observed'.
function M.movement_sample(builder, player_key, src, sample, opts)
  sample = sample or {}
  opts = opts or {}
  return builder:build{
    player_key   = player_key,
    src          = src,
    category     = 'movement',
    event        = 'movement_sample',
    source       = 'poll:entity_state',
    trust        = 'observed',
    measurements = {
      pos_x_m    = num(sample.x),
      pos_y_m    = num(sample.y),
      pos_z_m    = num(sample.z),
      vel_x_mps  = num(sample.vx),
      vel_y_mps  = num(sample.vy),
      vel_z_mps  = num(sample.vz),
      speed_mps  = num(sample.speed),
      heading_deg = num(sample.heading),
    },
    context = {
      in_vehicle = boolean_of(sample.in_vehicle),
      vehicle_model = num(sample.vehicle_model),
      bucket     = num(sample.bucket),
      is_ragdoll = boolean_of(sample.is_ragdoll),
      is_dead    = boolean_of(sample.is_dead),
    },
    correlation_id = opts.correlation_id,
  }
end

--[[
  Aim / camera sample -> aim record, trust = 'observed'.

  GET_PLAYER_CAMERA_ROTATION is a server native (audit §7.2), so this is genuinely
  server-observed rather than client-reported. Its update rate and precision are
  still UNMEASURED (EXP-001), which is why no aim detector consumes this yet --
  recording it is Phase 2 work, reasoning about it is blocked on the experiment.
]]
function M.aim_sample(builder, player_key, src, sample, opts)
  sample = sample or {}
  opts = opts or {}
  return builder:build{
    player_key   = player_key,
    src          = src,
    category     = 'aim',
    event        = 'aim_sample',
    source       = 'poll:camera_rotation',
    trust        = 'observed',
    measurements = {
      cam_pitch_deg = num(sample.pitch),
      cam_yaw_deg   = num(sample.yaw),
      cam_roll_deg  = num(sample.roll),
      focus_x_m     = num(sample.focus_x),
      focus_y_m     = num(sample.focus_y),
      focus_z_m     = num(sample.focus_z),
    },
    context = {
      free_cam      = boolean_of(sample.free_cam),
      weapon_hash   = num(sample.weapon_hash),
      in_vehicle    = boolean_of(sample.in_vehicle),
    },
    correlation_id = opts.correlation_id,
  }
end

--- System record. trust = 'observed'. player_key is always 'SYSTEM'.
function M.system(builder, event, measurements, context)
  return builder:build{
    player_key   = 'SYSTEM',
    category     = 'system',
    event        = event,
    source       = 'security-core',
    trust        = 'observed',
    measurements = measurements or {},
    context      = context or {},
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
SecLab.normalize = M

return M

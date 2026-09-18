--[[
  tests/unit/test_normalize.lua

  Normalizers are the boundary where attacker-controlled data enters the system,
  so these tests care most about two things:
    1. trust is labelled correctly (docs/TELEMETRY_SCHEMA.md §6)
    2. hostile payloads produce a valid record or no measurement -- never a crash,
       and never a fabricated number
]]
local H = ...
local clock     = require('logic.clock')
local envelope  = require('logic.envelope')
local normalize = require('logic.normalize')
local schema    = require('logic.schema')

local function builder()
  local t = 0
  return envelope.new(
    clock.new(function() return 1758204000000 end, function() t = t + 10; return t end),
    { mode = 'LAB' })
end

local function assert_valid(r, label)
  local ok, errs = schema.validate(r)
  H.ok(ok, (label or 'record') .. ' invalid: ' .. table.concat(errs, '; '))
end

-- A realistic weaponDamageEvent payload, field names per the official
-- server-events reference.
local function wde(over)
  local d = {
    weaponType = 453432689, weaponDamage = 35, damageType = 3, damageFlags = 8,
    damageTime = 123456, hitComponent = 3, hitGlobalId = 41,
    hitGlobalIds = { 41 }, parentGlobalId = 12,
    willKill = false, silenced = false, overrideDefaultDamage = false,
    hasVehicleData = false, isNetTargetPos = true,
    localPosX = 1.5, localPosY = -0.25, localPosZ = 0.75,
  }
  for k, v in pairs(over or {}) do
    if v == '__nil__' then d[k] = nil else d[k] = v end
  end
  return d
end

H.suite('normalize: weaponDamageEvent')

H.test('produces a valid combat record', function()
  local r = normalize.weapon_damage(builder(), 'QB:ABCD1234', 12, wde())
  assert_valid(r, 'weapon_damage')
  H.eq(r.category, 'combat')
  H.eq(r.event, 'weapon_damage')
  H.eq(r.source, 'event:weaponDamageEvent')
end)

H.test('labels the payload as CLAIMED, not observed', function()
  -- This is the single most important assertion in the file. The payload comes from
  -- the client; mislabelling it would let a detector treat a fabrication as a
  -- server-vouched measurement (docs/TRUST_BOUNDARY.md §5).
  H.eq(normalize.weapon_damage(builder(), 'QB:A', 1, wde()).trust, 'claimed')
end)

H.test('prefixes attacker-supplied measurements with claimed_', function()
  local m = normalize.weapon_damage(builder(), 'QB:A', 1, wde()).measurements
  for k in pairs(m) do
    H.ok(k:sub(1, 8) == 'claimed_', 'measurement ' .. k .. ' must be marked claimed_')
  end
end)

H.test('records damageTime dimensionless because its unit is undocumented', function()
  -- audit §7.3 / EXP-002: the clock base and unit of damageTime are unknown, so it
  -- must NOT be labelled _ms. The `_n` suffix encodes that uncertainty in the data.
  local m = normalize.weapon_damage(builder(), 'QB:A', 1, wde()).measurements
  H.eq(m.claimed_damage_time_n, 123456)
  H.is_nil(m.claimed_damage_time_ms, 'must not claim milliseconds we cannot verify')
end)

H.test('counts hit targets from hitGlobalIds', function()
  local m = normalize.weapon_damage(builder(), 'QB:A', 1,
    wde{ hitGlobalIds = { 41, 42, 43 } }).measurements
  H.eq(m.claimed_hit_targets_n, 3)
end)

H.test('falls back to hitGlobalId when the array is absent', function()
  local m = normalize.weapon_damage(builder(), 'QB:A', 1,
    wde{ hitGlobalIds = '__nil__', hitGlobalId = 41 }).measurements
  H.eq(m.claimed_hit_targets_n, 1)
end)

H.test('reports zero targets for a miss', function()
  local m = normalize.weapon_damage(builder(), 'QB:A', 1,
    wde{ hitGlobalIds = {}, hitGlobalId = 0 }).measurements
  H.eq(m.claimed_hit_targets_n, 0)
end)

H.suite('normalize: weaponDamageEvent under hostile input')

-- The payload originates on the attacker's machine. A normalizer that crashes is a
-- denial of service against our own observability, so each of these must survive.

H.test('survives an empty payload', function()
  assert_valid(normalize.weapon_damage(builder(), 'QB:A', 1, {}), 'empty payload')
end)

H.test('survives a nil payload', function()
  assert_valid(normalize.weapon_damage(builder(), 'QB:A', 1, nil), 'nil payload')
end)

H.test('drops string-typed numerics rather than coercing them', function()
  local m = normalize.weapon_damage(builder(), 'QB:A', 1,
    wde{ weaponDamage = '999999' }).measurements
  H.is_nil(m.claimed_damage_n, 'a string must be dropped, not silently coerced')
end)

H.test('drops NaN and infinite claims', function()
  local m = normalize.weapon_damage(builder(), 'QB:A', 1,
    wde{ weaponDamage = 0/0, localPosX = math.huge }).measurements
  H.is_nil(m.claimed_damage_n)
  H.is_nil(m.claimed_local_pos_x_m)
end)

H.test('survives a table where a number is expected', function()
  local r = normalize.weapon_damage(builder(), 'QB:A', 1,
    wde{ weaponDamage = { 1, 2 }, weaponType = { evil = true } })
  assert_valid(r, 'table-typed fields')
  H.is_nil(r.measurements.claimed_damage_n)
  H.is_nil(r.context.weapon_hash)
end)

H.test('survives a hitGlobalIds that is not an array', function()
  local r = normalize.weapon_damage(builder(), 'QB:A', 1,
    wde{ hitGlobalIds = 'not-an-array', hitGlobalId = '__nil__' })
  assert_valid(r)
  H.eq(r.measurements.claimed_hit_targets_n, 0)
end)

H.test('coerces truthy non-booleans to real booleans', function()
  local c = normalize.weapon_damage(builder(), 'QB:A', 1,
    wde{ willKill = 'yes', silenced = 0 }).context
  H.eq(c.will_kill, true)
  H.eq(c.silenced, true, 'Lua treats 0 as truthy; the record must hold a boolean')
end)

H.suite('normalize: explosionEvent')

H.test('produces a valid claimed combat record', function()
  local r = normalize.explosion(builder(), 'QB:A', 3, {
    explosionType = 2, posX = 742.84, posY = -1808.28, posZ = 33.1,
    damageScale = 1.0, cameraShake = 1.0, isAudible = true, isInvisible = false,
    ownerNetId = 0,
  })
  assert_valid(r, 'explosion')
  H.eq(r.trust, 'claimed')
  H.eq(r.context.explosion_type, 2)
  H.near(r.measurements.claimed_pos_x_m, 742.84, 1e-6)
end)

H.test('survives an empty explosion payload', function()
  assert_valid(normalize.explosion(builder(), 'QB:A', 3, {}))
end)

H.suite('normalize: packet loss scaling')

H.test('scales raw ENet packet loss to a percentage', function()
  -- ENET_PACKET_LOSS_SCALE = 65536 is documented; a factor-of-65536 error here
  -- would make every player look catastrophically lossy.
  H.near(normalize.packet_loss_pct(0), 0.0, 1e-9)
  H.near(normalize.packet_loss_pct(65536), 100.0, 1e-9)
  H.near(normalize.packet_loss_pct(6553.6), 10.0, 1e-6)
end)

H.test('returns nil for a missing or invalid raw value', function()
  H.is_nil(normalize.packet_loss_pct(nil))
  H.is_nil(normalize.packet_loss_pct('12'))
  H.is_nil(normalize.packet_loss_pct(0/0))
end)

H.suite('normalize: network sample')

H.test('produces a valid observed network record', function()
  local r = normalize.network_sample(builder(), 'QB:A', 5, {
    ping_ms = 48, rtt_ms = 52, rtt_variance_ms = 7,
    packet_loss_raw = 6553.6, packet_loss_variance = 2,
    packet_loss_epoch_ms = 9000, last_msg_ms = 30,
  })
  assert_valid(r, 'network_sample')
  H.eq(r.trust, 'observed')
  H.eq(r.category, 'network')
  H.near(r.measurements.packet_loss_pct, 10.0, 1e-6)
end)

H.test('carries staleness so fresh zeroes are distinguishable from old ones', function()
  -- audit §7.5: peer statistics refresh only every 10s. A detector must be able to
  -- tell "0% loss now" from "0% loss measured 9 seconds ago".
  local r = normalize.network_sample(builder(), 'QB:A', 5,
    { packet_loss_raw = 0, packet_loss_epoch_ms = 9500 })
  H.eq(r.measurements.stale_ms, 9500)
end)

H.suite('normalize: movement and aim samples')

H.test('movement sample is observed and valid', function()
  local r = normalize.movement_sample(builder(), 'QB:A', 5, {
    x = 100.5, y = -200.25, z = 30.0, vx = 1, vy = 2, vz = 0,
    speed = 2.236, heading = 180.0,
    in_vehicle = false, is_ragdoll = false, is_dead = false, bucket = 0,
  })
  assert_valid(r, 'movement_sample')
  H.eq(r.trust, 'observed')
  H.eq(r.category, 'movement')
end)

H.test('aim sample is observed and valid', function()
  local r = normalize.aim_sample(builder(), 'QB:A', 5, {
    pitch = -3.5, yaw = 122.0, roll = 0.0,
    focus_x = 10.0, focus_y = 20.0, focus_z = 30.0,
    free_cam = false, weapon_hash = 453432689, in_vehicle = false,
  })
  assert_valid(r, 'aim_sample')
  H.eq(r.trust, 'observed', 'camera rotation is a SERVER native (audit §7.2)')
  H.eq(r.category, 'aim')
end)

H.test('samples survive missing fields', function()
  assert_valid(normalize.movement_sample(builder(), 'QB:A', 5, {}))
  assert_valid(normalize.aim_sample(builder(), 'QB:A', 5, {}))
end)

H.suite('normalize: entity and lifecycle')

H.test('entity lifecycle is observed, since natives resolved it', function()
  local r = normalize.entity_lifecycle(builder(), 'QB:A', 5, 'creating', {
    handle = 65540, entity_type = 2, model = 1234, population_type = 6,
    owner_src = 5, script = 'qb-garages', bucket = 0,
  })
  assert_valid(r, 'entity_creating')
  H.eq(r.trust, 'observed')
  H.eq(r.event, 'entity_creating')
  H.eq(r.source, 'event:entityCreating')
end)

H.test('player lifecycle produces a valid observed record', function()
  local r = normalize.player_lifecycle(builder(), 'QB:A', 5, 'player_dropped',
    { reason = 'Exiting', session_ms = 1234567, source_event = 'playerDropped' })
  assert_valid(r, 'player_dropped')
  H.eq(r.trust, 'observed')
  H.eq(r.source, 'event:playerDropped')
end)

H.suite('normalize: system records')

H.test('system records use the SYSTEM key', function()
  local r = normalize.system(builder(), 'boot', { startup_ms = 12 }, { mode = 'LAB' })
  assert_valid(r, 'system boot')
  H.eq(r.player_key, 'SYSTEM')
  H.eq(r.category, 'system')
end)

H.suite('normalize: correlation')

H.test('correlation_id is carried through when supplied', function()
  local r = normalize.weapon_damage(builder(), 'QB:A', 1, wde(), { correlation_id = 'c_abc' })
  H.eq(r.correlation_id, 'c_abc')
end)

H.test('claimed and observed records can share a correlation id', function()
  -- This is the mechanism that lets a detector compare a claim against server
  -- geometry without either record mixing trust levels (see normalize.lua header).
  local b = builder()
  local claimed = normalize.weapon_damage(b, 'QB:A', 1, wde(), { correlation_id = 'c_1' })
  local observed = normalize.movement_sample(b, 'QB:A', 1, { x = 1, y = 2, z = 3 },
    { correlation_id = 'c_1' })
  H.eq(claimed.correlation_id, observed.correlation_id)
  H.eq(claimed.trust, 'claimed')
  H.eq(observed.trust, 'observed')
end)

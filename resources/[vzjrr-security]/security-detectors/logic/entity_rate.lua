--[[
  security-detectors / logic / entity_rate.lua

  PURE LUA. Detector #3: `entity.rate`.
  Design spec: detectors/entities/ENTITY-RATE.md

  ---------------------------------------------------------------------------
  READ THIS BEFORE ENABLING IT: CONFIGURATION COMES FIRST.

  `sv_entityLockdown` defaults to `inactive`, which the official documentation
  describes as "clients can create any entity". On such a server, spawn abuse is not a
  cheat to detect -- it is a PERMITTED OPERATION. `POSTURE-004` reports that ConVar.

  Recommending this detector to an operator running `inactive` would be advising them
  to monitor a door they have left open. This detector is for what remains after
  hardening.

  ---------------------------------------------------------------------------
  THREE HONESTY CONSTRAINTS, each of which shapes the code.

  1. THRESHOLDS ARE NOT SHIPPED. A rate is only abnormal relative to this server's own
     population, and a racing server spawns vehicles constantly where a roleplay
     server barely does. Every threshold defaults to 0, which means NOT CONFIGURED and
     produces no detections. The detector still counts, so the baseline can be derived
     from real data -- observatory first, accusations later.

  2. UNATTRIBUTED CREATIONS ARE NOT GUESSED. `entityCreating` carries only a handle,
     and `NetworkGetEntityOwner` is client-side, so many creations cannot be tied to a
     player. Those are counted separately and can never produce a player-keyed
     detection. Assigning them to the nearest player would be inventing evidence.

  3. A LOSSY WINDOW DOWNGRADES THE RESULT. If the bounded window evicted anything, the
     count is a floor rather than a measurement, and the detection says so and carries
     reduced confidence.
  ---------------------------------------------------------------------------
]]

local function sec_require(key, path)
  if SecLab and SecLab[key] then return SecLab[key] end
  return require(path)
end

local window_lib = sec_require('window', 'logic.window')

local M = {}

M.ID      = 'entity.rate'
M.VERSION = 1
M.KIND    = 'record'

-- Entity types, per GET_ENTITY_TYPE's documented return values.
M.ENTITY_TYPE_NAMES = { [1] = 'ped', [2] = 'vehicle', [3] = 'object' }

local function type_name(t)
  return M.ENTITY_TYPE_NAMES[t] or ('type' .. tostring(t or 'unknown'))
end

local function cfg_num(config, key, default)
  local v = (config or {})[key]
  if type(v) == 'number' then return v end
  return default
end

--[[
  Build the detector state. The adapter holds this and passes it to every call, which
  keeps the detector a deterministic function of (state, record) and therefore
  testable.
]]
function M.new_state(config)
  config = config or {}
  return {
    rate_window = window_lib.new{
      window_ms          = cfg_num(config, 'detectors.entity_rate.window_ms', 60000),
      max_keys           = cfg_num(config, 'detectors.entity_rate.max_keys', 512),
      max_events_per_key = cfg_num(config, 'detectors.entity_rate.max_events_per_key', 256),
    },
    churn_window = window_lib.new{
      window_ms          = cfg_num(config, 'detectors.entity_rate.churn_window_ms', 5000),
      max_keys           = cfg_num(config, 'detectors.entity_rate.max_keys', 512),
      max_events_per_key = cfg_num(config, 'detectors.entity_rate.max_events_per_key', 256),
    },
    -- handle -> { player_key, created_mono } so a removal can be paired with its
    -- creation. Bounded by the same max_keys budget via the window's own limits.
    live = {},
    live_n = 0,
    max_live = cfg_num(config, 'detectors.entity_rate.max_tracked_entities', 4096),
    -- Counted, never attributed. See honesty constraint 2.
    unattributed_n = 0,
    -- Per-detection de-duplication, so one sustained burst is one finding.
    last_fired = {},
  }
end

local function is_entity_record(record)
  return type(record) == 'table' and record.category == 'entity'
end

--- Only a QB-keyed or session-keyed player can own a rate. SYSTEM cannot.
local function attributable(player_key)
  if type(player_key) ~= 'string' then return false end
  if player_key == 'SYSTEM' then return false end
  return player_key:match('^QB:') ~= nil or player_key:match('^SRC:') ~= nil
end

--[[
  Evaluate the churn signal for one player. Shared by the creation and removal paths
  so there is a single implementation of the threshold, de-duplication and the
  lossy-window downgrade.
]]
function M._maybe_churn(state, config, player_key, mono, record, detection_new)
  local churn_min = cfg_num(config, 'detectors.entity_rate.min_churn_n', 0)
  if churn_min <= 0 then return nil end

  local churn_count = state.churn_window:count(player_key, mono)
  if churn_count < churn_min then return nil end

  local dedup_ms = cfg_num(config, 'detectors.entity_rate.redetect_ms', 30000)
  local dedup_key = player_key .. '|entity_churn'
  local last = state.last_fired[dedup_key]
  if last and (mono - last) < dedup_ms then return nil end
  state.last_fired[dedup_key] = mono

  local explanation = string.format(
    'This player created and removed %d entities within the churn lifetime in %dms. '
    .. 'Rapid create/remove cycling has no legitimate gameplay analogue this project '
    .. 'is aware of, and can indicate probing or an attempt to stay under a rate '
    .. 'threshold.', churn_count, state.churn_window:window_ms())

  local confidence = 0.6
  local lossy = state.rate_window:lossy() or state.churn_window:lossy()
  if lossy then
    confidence = math.min(confidence, 0.3)
    explanation = explanation
      .. ' NOTE: the counting window evicted events under load, so this count is a '
      .. 'FLOOR rather than an exact measurement and the confidence is reduced '
      .. 'accordingly.'
  end

  local ctx = (record or {}).context or {}
  local result, errs = detection_new({
    detector_id      = M.ID,
    detector_version = M.VERSION,
    player_key       = player_key,
    ts               = (record or {}).ts or 0,
    mono             = mono,
    signal           = 'entity_churn',
    severity         = 'medium',
    confidence       = confidence,
    trust_levels     = { 'observed', 'derived' },
    sources          = { 'event:entityCreating', 'event:entityRemoved' },
    measurements     = {
      churn_n     = churn_count,
      threshold_n = churn_min,
      window_ms   = state.churn_window:window_ms(),
    },
    evidence_refs    = (record or {}).correlation_id and { record.correlation_id } or {},
    explanation      = explanation,
    context          = { bucket = ctx.bucket, window_lossy = lossy },
  })
  if not result then
    error(('entity.rate could not build a churn result: %s')
      :format(table.concat(errs or {}, '; ')))
  end
  return result
end

--[[
  detect(state, record, config) -> DetectionResult | nil

  `deps.detection_new` is bound at construction by M.detector(deps).
]]
function M.detector(deps)
  assert(type(deps) == 'table' and type(deps.detection_new) == 'function',
    'entity_rate: deps.detection_new required')
  local detection_new = deps.detection_new

  return function(state, record, config)
    if not state or not is_entity_record(record) then return nil end

    local mono = record.mono
    if type(mono) ~= 'number' then return nil end

    local ctx = record.context or {}
    local player_key = record.player_key
    local event = record.event

    --[[
      Removals pair with their creation to measure churn.

      Churn is evaluated HERE as well as on creation. An earlier version only checked
      it on the next creation, which meant a churn burst that ended in removals --
      the natural shape of create/remove cycling -- was never reported at all.
    ]]
    if event == 'entity_removed' then
      local handle = (record.measurements or {}).handle_n
      local live = handle and state.live[handle] or nil
      if not live then return nil end

      state.live[handle] = nil
      state.live_n = state.live_n - 1
      if not attributable(live.player_key) then return nil end

      local lifetime = mono - (live.created_mono or mono)
      local churn_ms = cfg_num(config, 'detectors.entity_rate.churn_lifetime_ms', 2000)
      if lifetime < 0 or lifetime > churn_ms then return nil end

      state.churn_window:add(live.player_key, mono)
      return M._maybe_churn(state, config, live.player_key, mono, record, detection_new)
    end

    if event ~= 'entity_creating' and event ~= 'entity_created' then return nil end

    -- ---------- attribution ----------
    if not attributable(player_key) then
      --[[
        Counted, never guessed. `entityCreating` carries only a handle and
        NetworkGetEntityOwner is client-side, so a large share of creations genuinely
        cannot be tied to a player. Attributing them to the nearest one would be
        inventing evidence about a specific person.
      ]]
      state.unattributed_n = state.unattributed_n + 1
      return nil
    end

    --[[
      A creation owned by a resource script is that resource's, not the player's.
      Every legitimate spawner on a QBCore server (qb-garages, qb-vehicleshop, job
      scripts, admin menus) sets an entity script, so counting those against a player
      would make normal play look like abuse.

      Whether that assumption holds on THIS server is EXP-006's question, which is why
      the scriptless signal is separately gated below.
    ]]
    local owning_script = ctx.script
    if type(owning_script) == 'string' and owning_script ~= '' then
      return nil
    end

    local tname = type_name(ctx.entity_type)
    local key = player_key .. '|' .. tname

    local count = state.rate_window:add(key, mono)

    -- Track the handle so a later removal can be paired for churn.
    local handle = (record.measurements or {}).handle_n
    if handle and not state.live[handle] then
      if state.live_n < state.max_live then
        state.live[handle] = { player_key = player_key, created_mono = mono }
        state.live_n = state.live_n + 1
      end
    end

    -- ---------- signal 1: creation rate ----------
    local max_per_window = cfg_num(config, 'detectors.entity_rate.max_per_window', 0)

    local signal, measurements, base_confidence, explanation

    if max_per_window > 0 and count > max_per_window then
      signal = 'creation_rate'
      base_confidence = 0.5
      measurements = {
        created_n   = count,
        threshold_n = max_per_window,
        window_ms   = state.rate_window:window_ms(),
      }
      explanation = string.format(
        'This player created %d client-owned %s entities in %dms, above the '
        .. 'configured threshold of %d. No owning resource script was recorded for '
        .. 'them. Rates are server-observed; the threshold is this server\'s own '
        .. 'configured baseline, not a universal value.',
        count, tname, state.rate_window:window_ms(), max_per_window)

    else
      -- Not a rate finding: the creation may still complete a churn cycle.
      return M._maybe_churn(state, config, player_key, mono, record, detection_new)
    end

    -- ---------- de-duplicate a sustained burst ----------
    local dedup_ms = cfg_num(config, 'detectors.entity_rate.redetect_ms', 30000)
    local dedup_key = player_key .. '|' .. signal
    local last = state.last_fired[dedup_key]
    if last and (mono - last) < dedup_ms then return nil end
    state.last_fired[dedup_key] = mono

    -- ---------- honesty constraint 3: a lossy window is a floor ----------
    local confidence = base_confidence
    local lossy = state.rate_window:lossy() or state.churn_window:lossy()
    if lossy then
      confidence = math.min(confidence, 0.3)
      explanation = explanation
        .. ' NOTE: the counting window evicted events under load, so this count is a '
        .. 'FLOOR rather than an exact measurement and the confidence is reduced '
        .. 'accordingly.'
    end

    local result, errs = detection_new({
      detector_id      = M.ID,
      detector_version = M.VERSION,
      player_key       = player_key,
      ts               = record.ts or 0,
      mono             = mono,
      signal           = signal,
      severity         = 'low',
      confidence       = confidence,
      -- Counts derived from server-observed arrival times: the attacker controls
      -- neither our clock nor our counters.
      trust_levels     = { 'observed', 'derived' },
      sources          = { 'event:entityCreating', 'event:entityCreated' },
      measurements     = measurements,
      evidence_refs    = record.correlation_id and { record.correlation_id } or {},
      explanation      = explanation,
      context          = {
        entity_type     = tname,
        model_hash      = ctx.model_hash,
        population_type = ctx.population_type,
        bucket          = ctx.bucket,
        window_lossy    = lossy,
      },
    })

    if not result then
      error(('entity.rate could not build a result: %s')
        :format(table.concat(errs or {}, '; ')))
    end
    return result
  end
end

--- Housekeeping, called by the adapter on a timer.
function M.prune(state, mono)
  if not state then return 0 end
  local n = state.rate_window:prune(mono) + state.churn_window:prune(mono)
  return n
end

--- Drop everything held for a player, e.g. on playerDropped.
function M.forget(state, player_key)
  if not state or type(player_key) ~= 'string' then return end
  for _, name in ipairs({ 'ped', 'vehicle', 'object' }) do
    state.rate_window:forget(player_key .. '|' .. name)
  end
  state.churn_window:forget(player_key)
  for k in pairs(state.last_fired) do
    if k:sub(1, #player_key + 1) == player_key .. '|' then state.last_fired[k] = nil end
  end
end

function M.stats(state)
  if not state then return nil end
  return {
    rate_window    = state.rate_window:stats(),
    churn_window   = state.churn_window:stats(),
    live_entities_n = state.live_n,
    unattributed_n = state.unattributed_n,
  }
end

--- Registration spec for the registry.
function M.spec(deps)
  return { id = M.ID, version = M.VERSION, kind = M.KIND, fn = M.detector(deps) }
end

--[[
  DUAL EXPORT -- see docs/ARCHITECTURE.md §3.2 "Module loading".
]]
SecLab = SecLab or {}
SecLab.entity_rate = M

return M

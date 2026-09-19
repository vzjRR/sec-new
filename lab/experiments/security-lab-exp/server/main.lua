--[[
  security-lab-exp / server / main.lua

  ADAPTER. Runs the experiments that unblock detector work.

  LAB-ONLY. Refuses to start in PRODUCTION (charter §8). It reads state and records
  observations; it never mutates game state, never touches a player, and performs no
  enforcement.

  Two classes of experiment:

    STATIC   run at boot, need no player: EXP-004, 005, 006, 008, 009, 010
    SAMPLED  need a connected player, started by a console command:
             EXP-001 (camera), EXP-002 (weaponDamageEvent), EXP-003 (peer stats),
             EXP-007 (death timing)

  Sampled experiments are commands rather than automatic because they need a human to
  do something specific in-game, and because sampling at high frequency is a cost that
  should never start on its own.
]]

local function need(key)
  return assert(SecLab and SecLab[key],
    'security-lab-exp: module "' .. key .. '" did not load -- check fxmanifest order')
end

local source_scan = need('source_scan')
local R           = need('recorder')

local RESOURCE = GetCurrentResourceName()
local OUT_FILE = 'results/experiments.json'

local recorder
local armed = false

local function say(msg, ...)
  print(('[%s] %s'):format(RESOURCE, select('#', ...) > 0 and msg:format(...) or msg))
end

local function mono() return GetGameTimer() end

-- ===========================================================================
-- STATIC EXPERIMENTS
-- ===========================================================================

--- EXP-009 -- is `require` / `package` available to a resource script?
local function exp_009()
  local rt, pt = type(require), type(package)
  local ppath
  if pt == 'table' then ppath = tostring(rawget(package, 'path')) end

  recorder:record{
    id = 'EXP-009',
    question = 'Are require/package available to server-side resource scripts?',
    status = R.CONCLUDED,
    tag = 'OBSERVATION',
    finding = string.format(
      'require is %s and package is %s in a server resource script', rt, pt),
    detail = { require_type = rt, package_type = pt, package_path = ppath },
    blocks = 'confirms R-004 and the dual-export design',
  }
end

--- EXP-008 -- can a resource write files, and how?
local function exp_008()
  local detail = { io_type = type(io) }

  -- Path A: the standard Lua library.
  local io_ok, io_err = false, nil
  if type(io) == 'table' and type(io.open) == 'function' then
    local ok, fh = pcall(io.open, 'securitylab_io_probe.txt', 'a')
    if ok and fh then
      local wrote = pcall(function() fh:write('probe\n'); fh:flush(); fh:close() end)
      io_ok = wrote and true or false
      if not wrote then io_err = 'open succeeded but write failed' end
    else
      io_err = tostring(fh)
    end
  else
    io_err = 'io or io.open is not available'
  end
  detail.io_append_works = io_ok
  detail.io_error = io_err

  -- Path B: the documented native. Whole-file write, so not an append -- but
  -- supported, which matters if io turns out to be restricted.
  local save_ok = false
  if SaveResourceFile then
    save_ok = SaveResourceFile(RESOURCE, 'results/.probe', 'probe', -1) and true or false
  end
  detail.save_resource_file_works = save_ok
  detail.resource_path = GetResourcePath and GetResourcePath(RESOURCE) or nil

  recorder:record{
    id = 'EXP-008',
    question = 'Can a server resource append to files, and via which mechanism?',
    status = R.CONCLUDED,
    tag = 'OBSERVATION',
    finding = string.format(
      'io.open append %s; SaveResourceFile %s',
      io_ok and 'WORKS' or 'does NOT work',
      save_ok and 'works' or 'does not work'),
    detail = detail,
    blocks = 'the JSONL evidence sink',
  }
end

--- EXP-004 -- which qb-core is installed, and is the documented export available?
local function exp_004()
  local state = GetResourceState and GetResourceState('qb-core') or 'unknown'
  local detail = { qb_core_state = state }

  if state ~= 'started' then
    recorder:record{
      id = 'EXP-004',
      question = 'What qb-core version is installed and is GetPlayer exported?',
      status = R.INCONCLUSIVE,
      reason = 'qb-core resource state is "' .. tostring(state)
             .. '" -- it is not started, so nothing can be read from it',
      detail = detail,
      blocks = 'QBCore telemetry enrichment',
    }
    return
  end

  detail.version = GetResourceMetadata('qb-core', 'version', 0)
  detail.fx_version = GetResourceMetadata('qb-core', 'fx_version', 0)

  -- Probe the documented export WITHOUT a real player: calling GetPlayer with a
  -- source that cannot exist tells us whether the export is callable, which is the
  -- question, without touching anybody.
  local export_ok, export_err = pcall(function()
    return exports['qb-core']:GetPlayer(-1)
  end)
  detail.getplayer_callable = export_ok
  if not export_ok then detail.getplayer_error = tostring(export_err) end

  local core_ok = pcall(function() return exports['qb-core']:GetCoreObject({ 'Functions' }) end)
  detail.getcoreobject_selective_callable = core_ok

  recorder:record{
    id = 'EXP-004',
    question = 'What qb-core version is installed and is GetPlayer exported?',
    status = R.CONCLUDED,
    tag = 'OBSERVATION',
    finding = string.format('qb-core %s installed; GetPlayer export %s',
      tostring(detail.version or 'version-unknown'),
      export_ok and 'callable' or 'NOT callable'),
    detail = detail,
    blocks = 'QBCore telemetry enrichment',
  }
end

--- Enumerate started resources.
local function started_resources()
  local out = {}
  local n = GetNumResources and GetNumResources() or 0
  for i = 0, n - 1 do
    local name = GetResourceByFindIndex(i)
    if name and GetResourceState(name) == 'started' then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

--- Server-side script files a resource declares, via its manifest metadata.
local function server_scripts_of(res)
  local files = {}
  for _, key in ipairs({ 'server_script', 'shared_script' }) do
    local count = GetNumResourceMetadata(res, key) or 0
    for i = 0, count - 1 do
      local f = GetResourceMetadata(res, key, i)
      -- Globs cannot be expanded through this API, so they are reported rather than
      -- guessed at -- see the EXP-006 coverage note.
      if f and f ~= '' then files[#files + 1] = f end
    end
  end
  return files
end

--- EXP-006 -- inventory of client-triggerable server events across installed resources.
local function exp_006()
  local scans, skipped = {}, {}
  local resources = started_resources()

  for _, res in ipairs(resources) do
    for _, file in ipairs(server_scripts_of(res)) do
      if file:find('*', 1, true) then
        -- A glob cannot be resolved through the metadata API. Recording it as
        -- skipped keeps the inventory honest about its own coverage.
        skipped[#skipped + 1] = res .. '/' .. file
      else
        local src = LoadResourceFile(res, file)
        if src then
          scans[#scans + 1] = {
            resource = res, file = file,
            entries = source_scan.scan(src, { file = file }),
          }
        else
          skipped[#skipped + 1] = res .. '/' .. file .. ' (unreadable)'
        end
      end
    end
  end

  local inventory, stats = source_scan.inventory(scans)

  local net_events = {}
  for _, row in ipairs(inventory) do
    if row.kind == 'net_event' then net_events[#net_events + 1] = row end
  end

  recorder:record{
    id = 'EXP-006',
    question = 'Which resources register client-triggerable server events?',
    status = R.CONCLUDED,
    tag = 'OBSERVATION',
    finding = string.format(
      '%d net event registration(s) found across %d resource(s); this is a FLOOR, '
      .. 'not a complete list (%d dynamic name(s), %d file(s) unreadable or globbed)',
      #net_events, stats.resources_n, stats.dynamic_n, #skipped),
    samples_n = stats.entries_n,
    detail = {
      resources_scanned_n = stats.resources_n,
      files_scanned_n     = stats.files_n,
      net_events_n        = #net_events,
      dynamic_n           = stats.dynamic_n,
      skipped_n           = #skipped,
    },
    blocks = 'events.contract and economy detectors',
  }

  -- The full inventory goes to its own file: it is long, and it is the actual
  -- deliverable that contract work is built from.
  local payload = {
    generated_mono = mono(),
    inventory = inventory,
    stats = stats,
    skipped = skipped,
  }
  local ok, encoded = pcall(function()
    return exports['security-telemetry']:encodeLine(payload)
  end)
  if ok and type(encoded) == 'string' and SaveResourceFile then
    SaveResourceFile(RESOURCE, 'results/event-inventory.json', encoded, -1)
  end
end

--- EXP-005 -- do the documented QBCore SetMetaData weaknesses exist in the live source?
local function exp_005()
  if GetResourceState('qb-core') ~= 'started' then
    recorder:record{ id = 'EXP-005',
      question = 'Do the documented QBCore:Server:SetMetaData weaknesses exist in the live source?',
      status = R.INCONCLUSIVE, reason = 'qb-core is not started, so its source cannot be read',
      blocks = 'events.contract for QBCore events' }
    return
  end

  local hit_file, hit_src
  for _, file in ipairs(server_scripts_of('qb-core')) do
    if not file:find('*', 1, true) then
      local src = LoadResourceFile('qb-core', file)
      if src and src:find('QBCore:Server:SetMetaData', 1, true) then
        hit_file, hit_src = file, src
        break
      end
    end
  end

  if not hit_src then
    recorder:record{ id = 'EXP-005',
      question = 'Do the documented QBCore:Server:SetMetaData weaknesses exist in the live source?',
      status = R.INCONCLUSIVE,
      reason = 'no readable qb-core server script contains QBCore:Server:SetMetaData '
             .. '(it may be behind a glob, generated, or escrowed)',
      blocks = 'events.contract for QBCore events' }
    return
  end

  -- Isolate the handler body, then look for the three documented weaknesses.
  local at = hit_src:find('QBCore:Server:SetMetaData', 1, true)
  local body = hit_src:sub(at, at + 1200)
  local cleaned = source_scan.strip_lua(body)

  local has_upper_clamp = cleaned:find('>%s*100') ~= nil
  local has_lower_clamp = cleaned:find('<%s*0') ~= nil
  local has_type_check  = cleaned:find('type%s*%(') ~= nil

  recorder:record{
    id = 'EXP-005',
    question = 'Do the documented QBCore:Server:SetMetaData weaknesses exist in the live source?',
    status = R.CONCLUDED,
    tag = 'OBSERVATION',
    finding = string.format(
      'live handler in %s: upper clamp %s, lower clamp %s, type check %s',
      hit_file,
      has_upper_clamp and 'present' or 'ABSENT',
      has_lower_clamp and 'present' or 'ABSENT',
      has_type_check and 'present' or 'ABSENT'),
    detail = {
      file = hit_file,
      upper_clamp = has_upper_clamp,
      lower_clamp = has_lower_clamp,
      type_check  = has_type_check,
      note = 'lexical check of the handler region, not a proof; read the file to confirm',
    },
    blocks = 'events.contract for QBCore events',
  }
end

--- EXP-010 -- does a table containing functions survive an exports call?
local function exp_010()
  if GetResourceState('security-lab-exp-peer') ~= 'started' then
    recorder:record{ id = 'EXP-010',
      question = 'Does a table containing functions survive an exports call between resources?',
      status = R.SKIPPED,
      reason = 'the peer resource security-lab-exp-peer is not started; '
             .. 'ensure it and re-run',
      blocks = 'cross-resource design choices' }
    return
  end

  local ok, out = pcall(function()
    return exports['security-lab-exp-peer']:probeTable()
  end)

  if not ok then
    recorder:record{ id = 'EXP-010',
      question = 'Does a table containing functions survive an exports call between resources?',
      status = R.FAILED, reason = 'the peer export call raised: ' .. tostring(out),
      blocks = 'cross-resource design choices' }
    return
  end

  local fn_type = (type(out) == 'table') and type(out.fn) or 'n/a'
  local survived = fn_type == 'function'

  recorder:record{
    id = 'EXP-010',
    question = 'Does a table containing functions survive an exports call between resources?',
    status = R.CONCLUDED,
    tag = 'OBSERVATION',
    finding = survived
      and 'a table containing a function DOES survive an exports call'
      or  'a function inside a returned table does NOT survive an exports call',
    detail = {
      returned_type = type(out),
      fn_type = fn_type,
      plain_value = type(out) == 'table' and tostring(out.marker) or nil,
    },
    blocks = 'cross-resource design choices',
  }
end

-- ===========================================================================
-- SAMPLED EXPERIMENTS (commands)
-- ===========================================================================

local function resolve_player(arg)
  local src = tonumber(arg)
  if not src then return nil, 'give a player server id' end
  local ped = GetPlayerPed(src)
  if not ped or ped == 0 then return nil, 'player ' .. tostring(src) .. ' has no ped' end
  return src, nil
end

--[[
  EXP-001 -- characterise GET_PLAYER_CAMERA_ROTATION.

  Samples at a fixed high rate and measures how often the value actually CHANGES.
  That is the question that matters: if the native refreshes at 250ms, polling at
  50ms buys nothing, and the aim poller's current 500ms default is unjustified either
  way (docs/PERFORMANCE_BUDGET.md §3).
]]
local function exp_001(src, duration_ms, interval_ms)
  duration_ms = duration_ms or 20000
  interval_ms = interval_ms or 50

  local samples, changes = 0, 0
  local gaps = {}
  local last_vec, last_change_mono
  local deltas = {}
  local in_vehicle_n, free_cam_n = 0, 0
  local started = mono()

  while mono() - started < duration_ms do
    local s = tostring(src)
    local okc, rot = pcall(GetPlayerCameraRotation, s)
    if okc and rot then
      samples = samples + 1
      local x, y, z = rot.x, rot.y, rot.z
      if last_vec then
        local moved = (x ~= last_vec[1]) or (y ~= last_vec[2]) or (z ~= last_vec[3])
        if moved then
          changes = changes + 1
          if last_change_mono then gaps[#gaps + 1] = mono() - last_change_mono end
          last_change_mono = mono()
          local d = math.abs(z - last_vec[3])
          if d > 0 then deltas[#deltas + 1] = d end
        end
      else
        last_change_mono = mono()
      end
      last_vec = { x, y, z }
    end
    pcall(function()
      local ped = GetPlayerPed(src)
      if ped and ped ~= 0 then
        local veh = GetVehiclePedIsIn(ped)
        if veh and veh ~= 0 then in_vehicle_n = in_vehicle_n + 1 end
      end
      if IsPlayerInFreeCamMode(tostring(src)) then free_cam_n = free_cam_n + 1 end
    end)
    Wait(interval_ms)
  end

  local gap_stats = R.stats(gaps, 5)
  local delta_stats = R.stats(deltas, 5)

  if not gap_stats then
    recorder:record{ id = 'EXP-001',
      question = 'What are the update rate, precision and context behaviour of GET_PLAYER_CAMERA_ROTATION?',
      status = R.INCONCLUSIVE,
      reason = string.format(
        'only %d change(s) observed in %dms -- the player must MOVE THE CAMERA '
        .. 'continuously for the whole run', changes, duration_ms),
      detail = { samples_n = samples, changes_n = changes },
      blocks = 'ALL aim detection (EXP-001)' }
    return
  end

  recorder:record{
    id = 'EXP-001',
    question = 'What are the update rate, precision and context behaviour of GET_PLAYER_CAMERA_ROTATION?',
    status = R.CONCLUDED,
    tag = 'OBSERVATION',
    finding = string.format(
      'value changed %d times in %d samples; median gap between changes %.0fms '
      .. '(p90 %.0fms). Polling faster than that yields duplicates.',
      changes, samples, gap_stats.p50, gap_stats.p90),
    samples_n = samples,
    detail = {
      poll_interval_ms = interval_ms,
      duration_ms = duration_ms,
      changes_n = changes,
      change_gap_p50_ms = gap_stats.p50,
      change_gap_p90_ms = gap_stats.p90,
      change_gap_min_ms = gap_stats.min,
      yaw_delta_p50_deg = delta_stats and delta_stats.p50 or nil,
      yaw_delta_min_deg = delta_stats and delta_stats.min or nil,
      samples_in_vehicle_n = in_vehicle_n,
      samples_free_cam_n = free_cam_n,
    },
    blocks = 'ALL aim detection (EXP-001)',
  }
end

--[[
  EXP-003 -- how often do peer statistics actually refresh?

  The docs say every 10 seconds. That is worth confirming, because
  FALSE_POSITIVE_POLICY leans on `stale_ms` being meaningful.
]]
local function exp_003(src, duration_ms)
  duration_ms = duration_ms or 40000
  local PEER = { PacketLoss = 0, PacketLossEpoch = 2, RoundTripTime = 3 }
  local last, gaps, samples = nil, {}, 0
  local last_change = mono()
  local started = mono()
  local rtts = {}

  while mono() - started < duration_ms do
    local s = tostring(src)
    local ok, loss = pcall(GetPlayerPeerStatistics, s, PEER.PacketLoss)
    local _, rtt = pcall(GetPlayerPeerStatistics, s, PEER.RoundTripTime)
    if ok then
      samples = samples + 1
      if type(rtt) == 'number' then rtts[#rtts + 1] = rtt end
      if last ~= nil and loss ~= last then
        gaps[#gaps + 1] = mono() - last_change
        last_change = mono()
      end
      last = loss
    end
    Wait(500)
  end

  local gs = R.stats(gaps, 3)
  if not gs then
    recorder:record{ id = 'EXP-003',
      question = 'How often do peer statistics refresh, and how do they behave under impairment?',
      status = R.INCONCLUSIVE,
      reason = string.format(
        'packet loss did not change often enough in %dms to measure a refresh '
        .. 'cadence (%d change(s)); re-run while inducing loss', duration_ms, #gaps),
      detail = { samples_n = samples },
      blocks = 'network-conditioned thresholds' }
    return
  end

  recorder:record{
    id = 'EXP-003',
    question = 'How often do peer statistics refresh, and how do they behave under impairment?',
    status = R.CONCLUDED,
    tag = 'OBSERVATION',
    finding = string.format(
      'packet-loss value changed every ~%.0fms (median) over %d samples',
      gs.p50, samples),
    samples_n = samples,
    detail = {
      refresh_p50_ms = gs.p50, refresh_min_ms = gs.min, refresh_max_ms = gs.max,
      rtt_p50 = (R.stats(rtts, 5) or {}).p50,
    },
    blocks = 'network-conditioned thresholds',
  }
end

--[[
  EXP-002 -- capture raw weaponDamageEvent payloads.

  Records payloads verbatim so the undocumented fields (f104, f112, f120, f133) and
  damageTime's clock base can be analysed offline. This is a capture, not an analysis:
  the analysis happens against real data rather than being guessed at here.
]]
local capture = { active = false, rows = {}, started = nil }

AddEventHandler('weaponDamageEvent', function(sender, data)
  if not capture.active then return end
  if #capture.rows >= 2000 then return end   -- bounded, like everything else
  local row = { recv_mono = mono(), sender = sender, data = {} }
  if type(data) == 'table' then
    for k, v in pairs(data) do
      if type(v) ~= 'table' then row.data[k] = v end
    end
  end
  capture.rows[#capture.rows + 1] = row
end)

local function exp_002_stop()
  capture.active = false
  local n = #capture.rows

  if n == 0 then
    recorder:record{ id = 'EXP-002',
      question = 'What are damageTime, hitGlobalIds and the undocumented weaponDamageEvent fields?',
      status = R.INCONCLUSIVE,
      reason = 'no weaponDamageEvent fired during the capture window',
      blocks = 'derived combat measurements' }
    return 0
  end

  -- What we can say without guessing: whether damageTime looks like our clock.
  local dt_vs_recv = {}
  for _, r in ipairs(capture.rows) do
    if type(r.data.damageTime) == 'number' then
      dt_vs_recv[#dt_vs_recv + 1] = r.recv_mono - r.data.damageTime
    end
  end
  local offset = R.stats(dt_vs_recv, 5)

  local keys = {}
  for _, r in ipairs(capture.rows) do
    for k in pairs(r.data) do keys[k] = (keys[k] or 0) + 1 end
  end
  local key_list = {}
  for k in pairs(keys) do key_list[#key_list + 1] = k end
  table.sort(key_list)

  recorder:record{
    id = 'EXP-002',
    question = 'What are damageTime, hitGlobalIds and the undocumented weaponDamageEvent fields?',
    status = R.CONCLUDED,
    tag = 'OBSERVATION',
    finding = string.format(
      'captured %d payload(s); %d distinct field(s). damageTime vs our receive clock: '
      .. 'median offset %s (a stable offset means the same time base).',
      n, #key_list, offset and string.format('%.0f', offset.p50) or 'not measurable'),
    samples_n = n,
    detail = {
      fields = table.concat(key_list, ','),
      damagetime_offset_p50 = offset and offset.p50 or nil,
      damagetime_offset_stddev = offset and offset.stddev or nil,
    },
    blocks = 'derived combat measurements',
  }

  local ok, encoded = pcall(function()
    return exports['security-telemetry']:encodeLine({ rows = capture.rows })
  end)
  if ok and type(encoded) == 'string' and SaveResourceFile then
    SaveResourceFile(RESOURCE, 'results/weapondamage-capture.json', encoded, -1)
  end
  return n
end

--[[
  EXP-007 -- how reliably and how promptly is death observable server-side?

  Watches health and metadata.isdead and records the delta between them. combat
  .dead_shooter's grace_ms comes from this, and guessing it would mean false
  accusations against players on bad connections.
]]
local function exp_007(src, duration_ms)
  duration_ms = duration_ms or 60000
  local started = mono()
  local health_zero_at, isdead_at = nil, nil
  local deltas, deaths = {}, 0
  local saw_qb = false

  while mono() - started < duration_ms do
    local ped = GetPlayerPed(src)
    if ped and ped ~= 0 then
      local hp = GetEntityHealth(ped)
      local isdead = nil
      local ok, data = pcall(function()
        local p = exports['qb-core']:GetPlayer(src)
        return p and p.PlayerData and p.PlayerData.metadata
      end)
      if ok and type(data) == 'table' then
        saw_qb = true
        isdead = data.isdead and true or false
      end

      if hp ~= nil and hp <= 0 and not health_zero_at then health_zero_at = mono() end
      if isdead == true and not isdead_at then isdead_at = mono() end

      if health_zero_at and isdead_at then
        deltas[#deltas + 1] = isdead_at - health_zero_at
        deaths = deaths + 1
        health_zero_at, isdead_at = nil, nil
      end
      if hp and hp > 0 then health_zero_at, isdead_at = nil, nil end
    end
    Wait(50)
  end

  if deaths == 0 then
    recorder:record{ id = 'EXP-007',
      question = 'Is metadata.isdead reliably set server-side at the moment of death?',
      status = R.INCONCLUSIVE,
      reason = string.format('no death observed in %dms -- the player must die at '
        .. 'least twice during the run', duration_ms),
      detail = { qbcore_metadata_readable = saw_qb },
      blocks = 'combat.dead_shooter grace_ms' }
    return
  end

  local ds = R.stats(deltas, 2)
  recorder:record{
    id = 'EXP-007',
    question = 'Is metadata.isdead reliably set server-side at the moment of death?',
    status = R.CONCLUDED,
    tag = 'OBSERVATION',
    finding = string.format(
      '%d death(s) observed; isdead lagged health<=0 by a median of %sms',
      deaths, ds and string.format('%.0f', ds.p50) or 'n/a'),
    samples_n = deaths,
    detail = {
      qbcore_metadata_readable = saw_qb,
      isdead_lag_p50_ms = ds and ds.p50 or nil,
      isdead_lag_max_ms = ds and ds.max or nil,
    },
    blocks = 'combat.dead_shooter grace_ms',
  }
end

-- ===========================================================================
-- Output
-- ===========================================================================

local function write_results()
  local bundle = recorder:bundle()
  local ok, encoded = pcall(function()
    return exports['security-telemetry']:encodeLine(bundle)
  end)
  if ok and type(encoded) == 'string' and SaveResourceFile then
    SaveResourceFile(RESOURCE, OUT_FILE, encoded, -1)
    say('results written to %s/%s', RESOURCE, OUT_FILE)
  else
    say('WARNING: could not write results file (%s). Copy the console output instead.',
      tostring(encoded))
  end
end

local function report()
  print('\n' .. recorder:render() .. '\n')
  write_results()
end

-- ===========================================================================
-- Boot
-- ===========================================================================

local function boot()
  local mode = 'UNKNOWN'
  local ok = pcall(function() mode = exports['security-core']:getMode() end)
  if not ok then
    -- Fail closed: if the mode cannot be established, assume PRODUCTION.
    mode = 'PRODUCTION'
  end

  if mode ~= 'LAB' then
    say('REFUSING TO START: security_mode is %s, not LAB.', tostring(mode))
    say('This is a lab-only measurement harness (charter §8). '
      .. 'Set `set security_mode "LAB"` in server.cfg to use it.')
    return
  end

  armed = true
  recorder = R.new({
    mode = mode,
    build = GetConvar and GetConvar('version', 'unknown') or 'unknown',
  })

  say('LAB experiment harness armed.')
  say('running static experiments (EXP-004, 005, 006, 008, 009, 010)...')

  for name, fn in pairs({
    ['EXP-009'] = exp_009, ['EXP-008'] = exp_008, ['EXP-004'] = exp_004,
    ['EXP-006'] = exp_006, ['EXP-005'] = exp_005, ['EXP-010'] = exp_010,
  }) do
    local okx, err = pcall(fn)
    if not okx then
      recorder:record{ id = name, status = R.FAILED,
        reason = 'probe raised: ' .. tostring(err) }
    end
  end

  report()

  say('SAMPLED experiments need a player and a human. Run these from the console:')
  say('  exp001 <playerId> [durationMs] [intervalMs]  -- camera; MOVE THE CAMERA throughout')
  say('  exp003 <playerId> [durationMs]               -- peer statistics cadence')
  say('  exp007 <playerId> [durationMs]               -- death timing; DIE a few times')
  say('  exp002start / exp002stop                     -- capture weaponDamageEvent payloads')
  say('  expreport                                    -- re-print and re-write results')
end

local function guard(fn)
  return function(source, args)
    if source ~= 0 then
      -- Console only. A lab harness must not be driveable by a connected player.
      return
    end
    if not armed then
      say('harness is not armed (LAB mode required)')
      return
    end
    fn(args or {})
  end
end

RegisterCommand('exp001', guard(function(args)
  local src, err = resolve_player(args[1])
  if not src then return say('exp001: %s', err) end
  say('exp001: sampling player %s -- MOVE THE CAMERA CONTINUOUSLY', tostring(src))
  CreateThread(function()
    exp_001(src, tonumber(args[2]), tonumber(args[3]))
    report()
  end)
end), true)

RegisterCommand('exp003', guard(function(args)
  local src, err = resolve_player(args[1])
  if not src then return say('exp003: %s', err) end
  say('exp003: sampling peer statistics for player %s', tostring(src))
  CreateThread(function() exp_003(src, tonumber(args[2])); report() end)
end), true)

RegisterCommand('exp007', guard(function(args)
  local src, err = resolve_player(args[1])
  if not src then return say('exp007: %s', err) end
  say('exp007: watching player %s -- DIE AT LEAST TWICE during the run', tostring(src))
  CreateThread(function() exp_007(src, tonumber(args[2])); report() end)
end), true)

RegisterCommand('exp002start', guard(function()
  capture.rows, capture.active, capture.started = {}, true, mono()
  say('exp002: capturing weaponDamageEvent payloads -- go and shoot things, then run exp002stop')
end), true)

RegisterCommand('exp002stop', guard(function()
  local n = exp_002_stop()
  say('exp002: captured %d payload(s)', n)
  report()
end), true)

RegisterCommand('expreport', guard(function() report() end), true)

AddEventHandler('onResourceStart', function(resource)
  if resource ~= RESOURCE then return end
  local ok, err = pcall(boot)
  if not ok then say('FATAL during boot: %s', tostring(err)) end
end)

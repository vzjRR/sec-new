--[[
  security-core / lib / config.lua

  PURE LUA. Declarative config schema with typed defaults, validation and merge.

  Validation matters more than it looks: a mistyped poll interval of 0 would turn a
  sampler into a busy loop on a live game server, and a negative threshold would make
  a detector fire on everyone. Bad config is a self-inflicted outage or a mass false
  positive, so config is validated rather than trusted.
]]

local M = {}

--[[
  Each entry: { default, type, min, max, one_of, doc }
  Poll intervals carry justification because charter §15 forbids high-frequency
  collection where a lower rate suffices.
]]
M.SCHEMA = {
  ['mode'] = {
    default = 'PRODUCTION', type = 'string', one_of = { 'LAB', 'PRODUCTION' },
    doc = 'Resolved from the security_mode ConVar. Fails closed to PRODUCTION.',
  },
  ['log_level'] = {
    default = 'info', type = 'string', one_of = { 'debug', 'info', 'warn', 'error' },
    doc = 'Minimum level written. debug is LAB-only in practice.',
  },
  ['telemetry.enabled'] = {
    default = true, type = 'boolean',
    doc = 'Master switch for the telemetry pipeline.',
  },
  ['telemetry.sink'] = {
    default = 'jsonl', type = 'string', one_of = { 'jsonl', 'stdout', 'memory', 'none' },
    doc = 'Where normalized records go. memory is for tests.',
  },
  ['telemetry.validate_records'] = {
    default = true, type = 'boolean',
    doc = 'Run schema validation on every record. Cheap, and catches adapter bugs '
       .. 'before they poison the evidence store.',
  },
  ['telemetry.buffer_size'] = {
    default = 2048, type = 'number', min = 16, max = 65536,
    doc = 'Ring buffer capacity before flush. Bounded so a telemetry spike cannot '
       .. 'exhaust server memory (charter §15).',
  },
  ['poll.movement_ms'] = {
    default = 1000, type = 'number', min = 100, max = 60000,
    doc = 'Movement sampling. 1s balances teleport visibility against cost; sub-100ms '
       .. 'is refused because it would poll faster than sync updates arrive.',
  },
  ['poll.network_ms'] = {
    default = 10000, type = 'number', min = 5000, max = 120000,
    doc = 'Peer statistics refresh only once per 10s server-side (audit §7.5), so '
       .. 'polling faster is pure waste. The 5s floor reflects that.',
  },
  ['poll.aim_ms'] = {
    default = 500, type = 'number', min = 50, max = 10000,
    doc = 'Camera rotation sampling. Provisional: the natives update rate is '
       .. 'UNMEASURED (EXP-001), so this default is a placeholder, not a finding.',
  },
  ['poll.player_state_ms'] = {
    default = 5000, type = 'number', min = 1000, max = 120000,
    doc = 'Health, armour, weapon, vehicle, job.',
  },
  ['posture.audit_on_boot'] = {
    default = true, type = 'boolean',
    doc = 'Run the ConVar posture audit at startup.',
  },
  ['posture.recheck_ms'] = {
    default = 300000, type = 'number', min = 60000, max = 3600000,
    doc = 'ConVars can change at runtime; re-audit occasionally. 5 minutes.',
  },
  ['framework.qbcore'] = {
    default = true, type = 'boolean',
    doc = 'Enable QBCore enrichment. Degrades silently if qb-core is absent.',
  },
  ['framework.resolve_retry_ms'] = {
    default = 2000, type = 'number', min = 250, max = 30000,
    doc = 'Retry interval for resolving a citizenid after playerJoining. There is no '
       .. 'DOCUMENTED server-side player-loaded event in QBCore, so we poll rather '
       .. 'than depend on an unverified event name (QBCORE_INTEGRATION.md §1).',
  },
  ['framework.resolve_timeout_ms'] = {
    default = 60000, type = 'number', min = 5000, max = 600000,
    doc = 'Give up resolving a citizenid after this long; the session stays SRC-keyed.',
  },
  ['detectors.enabled'] = {
    default = false, type = 'boolean',
    doc = 'Detection is OFF by default. Phase 2 is observation only (charter §4).',
  },
}

local function split_path(p)
  local out = {}
  for part in p:gmatch('[^%.]+') do out[#out + 1] = part end
  return out
end

--- Build the default config as a flat key table.
function M.defaults()
  local out = {}
  for k, spec in pairs(M.SCHEMA) do out[k] = spec.default end
  return out
end

--- Validate a flat config table against the schema.
-- @return ok boolean, errors table
function M.validate(cfg)
  local errs = {}
  local function err(fmt, ...) errs[#errs + 1] = string.format(fmt, ...) end

  if type(cfg) ~= 'table' then return false, { 'config is not a table' } end

  for k, v in pairs(cfg) do
    local spec = M.SCHEMA[k]
    if not spec then
      err('unknown config key %q', k)
    else
      if type(v) ~= spec.type then
        err('config %q: expected %s, got %s', k, spec.type, type(v))
      else
        if spec.one_of then
          local hit = false
          for _, allowed in ipairs(spec.one_of) do if v == allowed then hit = true end end
          if not hit then
            err('config %q: %q is not one of {%s}', k, tostring(v),
              table.concat(spec.one_of, ', '))
          end
        end
        if spec.type == 'number' then
          if v ~= v then err('config %q is NaN', k) end
          if spec.min and v < spec.min then
            err('config %q: %s is below the minimum %s', k, tostring(v), tostring(spec.min))
          end
          if spec.max and v > spec.max then
            err('config %q: %s is above the maximum %s', k, tostring(v), tostring(spec.max))
          end
        end
      end
    end
  end

  return #errs == 0, errs
end

--[[
  Merge overrides onto defaults, returning a validated config.

  An invalid override is REJECTED and the default is kept, with the problem reported.
  It does not abort startup: a security platform that refuses to boot because of one
  bad config line leaves the server with no observability at all, which is worse than
  running with a default. The rejection is logged loudly instead.

  @return cfg table, problems table
]]
function M.build(overrides)
  local cfg = M.defaults()
  local problems = {}

  for k, v in pairs(overrides or {}) do
    local spec = M.SCHEMA[k]
    if not spec then
      problems[#problems + 1] = string.format('ignored unknown config key %q', k)
    else
      local candidate = {}
      for ck, cv in pairs(cfg) do candidate[ck] = cv end
      candidate[k] = v
      local ok, errs = M.validate(candidate)
      if ok then
        cfg[k] = v
      else
        problems[#problems + 1] = string.format(
          'rejected %q (%s); keeping default %s', k, errs[1] or 'invalid',
          tostring(spec.default))
      end
    end
  end

  return cfg, problems
end

--- Documentation dump, used to generate config/README.
function M.describe()
  local keys = {}
  for k in pairs(M.SCHEMA) do keys[#keys + 1] = k end
  table.sort(keys)
  local lines = {}
  for _, k in ipairs(keys) do
    local s = M.SCHEMA[k]
    lines[#lines + 1] = string.format('%s = %s  (%s)\n    %s',
      k, tostring(s.default), s.type, s.doc or '')
  end
  return table.concat(lines, '\n')
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
SecLab.config = M

return M

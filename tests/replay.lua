--[[
  tests/replay.lua -- the fixture replay harness.

  Replays recorded inputs through the real detector pipeline and compares the outcome
  against what the fixture says should happen. This is the Tier B -> Tier A bridge
  (docs/ARCHITECTURE.md §2 C3): a capture from the lab becomes a permanent regression
  test that needs no game client.

  Usage:
    lua5.4 tests/replay.lua              # replay everything
    lua5.4 tests/replay.lua <id>         # replay one fixture
    lua5.4 tests/replay.lua --write <id> # create a missing `expected` block

  ---------------------------------------------------------------------------
  THE RULE THIS HARNESS ENFORCES

  A fixture is NEVER rewritten to match new code. Doing so destroys the regression
  signal it existed to provide, and does it silently.

  So `--write` REFUSES to overwrite an existing `expected` block. It only fills in a
  missing one. If behaviour genuinely changed for a good reason, the fixture is
  deleted and a new one created under a new name with a decision record -- which shows
  up in the diff instead of hiding in a rewrite.
  ---------------------------------------------------------------------------
]]

local ROOT = 'resources/[vzjrr-security]/'
package.path = table.concat({
  ROOT .. 'security-telemetry/?.lua',
  ROOT .. 'security-core/?.lua',
  ROOT .. 'security-forensics/?.lua',
  ROOT .. 'security-detectors/?.lua',
  './?.lua',
  package.path,
}, ';')

local J           = require('logic.jsonl')
local schema      = require('logic.schema')
local posture_lib = require('lib.posture')
local detection   = require('logic.detection')
local registry_lib= require('logic.registry')
local sp          = require('logic.server_posture')

local FIXTURE_DIR = 'lab/fixtures'

local RESET, RED, GREEN, YELLOW, DIM = '\27[0m', '\27[31m', '\27[32m', '\27[33m', '\27[2m'

-- ---------------------------------------------------------------------------
-- Fixture loading and validation
-- ---------------------------------------------------------------------------

local REQUIRED_META = {
  'id', 'kind', 'origin', 'captured', 'tier', 'description', 'schema_version',
}

local VALID_KIND   = { posture = true, telemetry = true }
local VALID_ORIGIN = { synthetic = true, capture = true }

local function read_file(path)
  local fh = io.open(path, 'r')
  if not fh then return nil, 'cannot open ' .. path end
  local body = fh:read('a'); fh:close()
  return body
end

--- Validate the provenance block. A fixture with no provenance cannot be trusted.
local function validate_meta(meta, id)
  local errs = {}
  if type(meta) ~= 'table' then return { 'missing meta block' } end
  for _, f in ipairs(REQUIRED_META) do
    if meta[f] == nil or meta[f] == '' then
      errs[#errs + 1] = string.format('meta.%s is required', f)
    end
  end
  if meta.kind and not VALID_KIND[meta.kind] then
    errs[#errs + 1] = string.format('meta.kind %q is not a known runner', tostring(meta.kind))
  end
  if meta.origin and not VALID_ORIGIN[meta.origin] then
    errs[#errs + 1] = string.format('meta.origin %q must be "synthetic" or "capture"',
      tostring(meta.origin))
  end
  --[[
    A telemetry fixture must be a real capture. A hand-written weaponDamageEvent
    proves only that we can imagine one; it says nothing about how the game actually
    behaves, and treating it as evidence would overstate our coverage.
  ]]
  if meta.kind == 'telemetry' and meta.origin == 'synthetic' then
    errs[#errs + 1] =
      'a telemetry fixture must have origin "capture": a hand-written record proves '
      .. 'nothing about real behaviour (see lab/fixtures/README.md §3)'
  end
  if meta.origin == 'capture' and meta.tier ~= 'B' then
    errs[#errs + 1] = 'a capture must declare tier "B"'
  end
  if meta.id and id and meta.id ~= id then
    errs[#errs + 1] = string.format('meta.id %q does not match directory %q',
      tostring(meta.id), id)
  end
  if meta.schema_version ~= nil and meta.schema_version ~= schema.SCHEMA_VERSION then
    -- Not fatal: an older fixture is exactly what a regression suite should keep.
    errs.schema_note = string.format(
      'fixture is schema v%s; this build speaks v%d',
      tostring(meta.schema_version), schema.SCHEMA_VERSION)
  end
  return errs
end

local function load_fixture(id)
  local path = string.format('%s/%s/fixture.json', FIXTURE_DIR, id)
  local body, err = read_file(path)
  if not body then return nil, err end
  local data, derr = J.decode(body)
  if not data then return nil, string.format('%s: %s', path, derr) end
  return { id = id, path = path, data = data }
end

local function list_fixture_ids()
  local ids = {}
  local p = io.popen(string.format(
    'find %s -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort', FIXTURE_DIR))
  if p then
    for line in p:lines() do ids[#ids + 1] = line:match('([^/]+)$') end
    p:close()
  end
  return ids
end

-- ---------------------------------------------------------------------------
-- Runners
-- ---------------------------------------------------------------------------

local function new_registry()
  local r = registry_lib.new({ detection_new = detection.new })
  local ok, err = r:register(sp.spec({ detection_new = detection.new }))
  if not ok then error('could not register server.posture: ' .. tostring(err)) end
  return r
end

--- Normalise a detection into the comparable shape. Prose is deliberately excluded:
--- explanations are expected to improve, and comparing them would make every fixture
--- break on an editorial change -- which trains people to rewrite fixtures.
local function comparable(results)
  local out = {}
  for _, d in ipairs(results) do
    out[#out + 1] = {
      signal = d.signal, severity = d.severity, confidence = d.confidence,
    }
  end
  table.sort(out, function(a, b) return tostring(a.signal) < tostring(b.signal) end)
  return out
end

local RUNNERS = {}

RUNNERS.posture = function(input)
  local convars = (input or {}).convars or {}
  local findings, summary = posture_lib.audit(convars)
  local blind, blind_reason = posture_lib.is_blind(convars)
  local r = new_registry()
  local results, errors = r:run_periodic({
    findings = findings, summary = summary,
    blind = blind, blind_reason = blind_reason,
    ts = 0, mono = 0,
  }, { ['detectors.enabled'] = true })
  return results, errors
end

RUNNERS.telemetry = function(input)
  --[[
    Replays records through the 'record' detectors. There are none yet (every
    behavioural detector is blocked on an experiment), so this currently yields
    nothing -- but the plumbing is exercised, and records are schema-validated, which
    is itself a real regression check on a capture.
  ]]
  local records = (input or {}).records or {}
  local r = new_registry()
  local all_results, all_errors = {}, {}
  local invalid = {}
  for i, rec in ipairs(records) do
    local ok, verrs = schema.validate(rec)
    if not ok then
      invalid[#invalid + 1] = string.format('record %d: %s', i, verrs[1] or 'invalid')
    end
    local results, errors = r:run_record({}, rec, { ['detectors.enabled'] = true })
    for _, x in ipairs(results) do all_results[#all_results + 1] = x end
    for _, e in ipairs(errors) do all_errors[#all_errors + 1] = e end
  end
  for _, m in ipairs(invalid) do
    all_errors[#all_errors + 1] = { detector_id = 'schema', err = m }
  end
  return all_results, all_errors
end

-- ---------------------------------------------------------------------------
-- Comparison
-- ---------------------------------------------------------------------------

local function diff(expected, actual)
  local problems = {}
  local function key(d) return tostring(d.signal) end

  local exp_by, act_by = {}, {}
  for _, d in ipairs(expected or {}) do exp_by[key(d)] = d end
  for _, d in ipairs(actual or {}) do act_by[key(d)] = d end

  for k, e in pairs(exp_by) do
    local a = act_by[k]
    if not a then
      problems[#problems + 1] = string.format('MISSING  %s was expected but not produced', k)
    else
      if e.severity ~= a.severity then
        problems[#problems + 1] = string.format(
          'SEVERITY %s: expected %s, got %s', k, tostring(e.severity), tostring(a.severity))
      end
      if e.confidence and math.abs((e.confidence or 0) - (a.confidence or 0)) > 1e-9 then
        problems[#problems + 1] = string.format(
          'CONFIDENCE %s: expected %s, got %s', k,
          tostring(e.confidence), tostring(a.confidence))
      end
    end
  end
  for k in pairs(act_by) do
    if not exp_by[k] then
      problems[#problems + 1] = string.format('UNEXPECTED %s was produced', k)
    end
  end
  table.sort(problems)
  return problems
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

local function replay(fixture, opts)
  local data = fixture.data
  local meta = data.meta
  local meta_errs = validate_meta(meta, fixture.id)

  local result = {
    id = fixture.id, meta = meta, problems = {},
    schema_note = meta_errs.schema_note,
  }

  for _, e in ipairs(meta_errs) do
    result.problems[#result.problems + 1] = 'META  ' .. e
  end
  if #result.problems > 0 then
    result.status = 'invalid'
    return result
  end

  local runner = RUNNERS[meta.kind]
  local ok, results, errors = pcall(runner, data.input)
  if not ok then
    result.status = 'error'
    result.problems = { 'RUNNER  ' .. tostring(results) }
    return result
  end

  result.actual = comparable(results)
  result.runner_errors = errors

  for _, e in ipairs(errors or {}) do
    result.problems[#result.problems + 1] =
      string.format('DETECTOR %s: %s', tostring(e.detector_id), tostring(e.err))
  end

  local expected = data.expected and data.expected.detections
  if expected == nil then
    if opts.write then
      -- Only ever FILLS IN a missing block; never replaces one.
      data.expected = { detections = result.actual }
      local encoded, eerr = J.encode(data)
      if not encoded then
        result.status = 'error'
        result.problems = { 'ENCODE  ' .. tostring(eerr) }
        return result
      end
      local fh = io.open(fixture.path, 'w')
      if not fh then
        result.status = 'error'
        result.problems = { 'WRITE  cannot write ' .. fixture.path }
        return result
      end
      fh:write(encoded, '\n'); fh:close()
      result.status = 'written'
      return result
    end
    result.status = 'invalid'
    result.problems[#result.problems + 1] =
      'META  no expected block; run with --write to create one'
    return result
  end

  if opts.write then
    -- The enforcement point for rule 1.
    result.status = 'refused'
    result.problems = {
      'REFUSED  this fixture already has an expected block. A fixture is never '
      .. 'rewritten to match new code (lab/fixtures/README.md §1). If behaviour '
      .. 'genuinely changed, delete this fixture, create a new one under a new name, '
      .. 'and record the decision.',
    }
    return result
  end

  local d = diff(expected, result.actual)
  for _, p in ipairs(d) do result.problems[#result.problems + 1] = p end
  result.status = #result.problems == 0 and 'pass' or 'fail'
  return result
end

local function main(argv)
  local opts = { write = false }
  local only
  for _, a in ipairs(argv) do
    if a == '--write' then opts.write = true else only = a end
  end

  local ids = only and { only } or list_fixture_ids()
  if #ids == 0 then
    io.write('no fixtures found under ', FIXTURE_DIR, '/\n')
    return 0
  end

  local counts = { pass = 0, fail = 0, invalid = 0, error = 0, written = 0, refused = 0 }
  local origins = { synthetic = 0, capture = 0 }

  io.write(YELLOW, 'fixture replay', RESET, '\n')
  for _, id in ipairs(ids) do
    local fx, err = load_fixture(id)
    if not fx then
      counts.error = counts.error + 1
      io.write('  ', RED, 'ERROR', RESET, '  ', id, '\n          ', RED, tostring(err), RESET, '\n')
    else
      local r = replay(fx, opts)
      counts[r.status] = (counts[r.status] or 0) + 1
      if r.meta and r.meta.origin then
        origins[r.meta.origin] = (origins[r.meta.origin] or 0) + 1
      end
      local colour = (r.status == 'pass' or r.status == 'written') and GREEN or RED
      io.write('  ', colour, string.upper(r.status), RESET, '  ', id)
      if r.meta and r.meta.origin then
        io.write(DIM, '  [', r.meta.origin, ', tier ', tostring(r.meta.tier), ']', RESET)
      end
      io.write('\n')
      if r.schema_note then
        io.write('          ', YELLOW, r.schema_note, RESET, '\n')
      end
      for _, p in ipairs(r.problems) do
        io.write('          ', RED, p, RESET, '\n')
      end
    end
  end

  io.write('\n', string.rep('-', 60), '\n')
  io.write(string.format('%d fixture(s): %d pass, %d fail, %d invalid, %d error',
    #ids, counts.pass, counts.fail, counts.invalid, counts.error))
  if counts.written > 0 then io.write(string.format(', %d written', counts.written)) end
  if counts.refused > 0 then io.write(string.format(', %d refused', counts.refused)) end
  io.write('\n')

  --[[
    Origins are reported separately so a green run cannot imply coverage that does not
    exist. Synthetic fixtures prove the logic behaves as specified; only captures say
    anything about real behaviour.
  ]]
  io.write(string.format('origin: %d synthetic, %d capture\n',
    origins.synthetic or 0, origins.capture or 0))
  if (origins.capture or 0) == 0 then
    io.write(YELLOW,
      'no captured fixtures yet: nothing here has been replayed against real server data\n',
      RESET)
  end

  local bad = counts.fail + counts.invalid + counts.error + counts.refused
  return bad == 0 and 0 or 1
end

os.exit(main({ ... }))

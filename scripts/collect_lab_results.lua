--[[
  scripts/collect_lab_results.lua

  Collects experiment results from a live server into the repository, validates them
  with this project's own JSON decoder, and reports what is unblocked.

  Run via scripts/collect-lab-results.sh. Intended for a session running ON the server
  machine (docs/LOCAL_SESSION.md).

  It VALIDATES rather than just copying, because a truncated or half-written results
  file that silently becomes "the evidence" is exactly the failure this project keeps
  guarding against. A file that does not parse is reported, not imported.
]]

package.path = table.concat({
  'resources/[vzjrr-security]/security-telemetry/?.lua',
  'lab/experiments/security-lab-exp/?.lua',
  './?.lua',
  package.path,
}, ';')

local J = require('logic.jsonl')
local R = require('logic.recorder')

local RESET, RED, GREEN, YELLOW, DIM = '\27[0m', '\27[31m', '\27[32m', '\27[33m', '\27[2m'

local WANTED = {
  { file = 'experiments.json',           required = true,
    what = 'the experiment results' },
  { file = 'event-inventory.json',       required = false,
    what = 'the EXP-006 event inventory' },
  { file = 'weapondamage-capture.json',  required = false,
    what = 'the EXP-002 raw payload capture' },
}

local function read_file(path)
  local fh = io.open(path, 'rb')
  if not fh then return nil end
  local body = fh:read('a'); fh:close()
  return body
end

local function write_file(path, body)
  local fh = io.open(path, 'wb')
  if not fh then return false, 'cannot write ' .. path end
  fh:write(body); fh:close()
  return true
end

local function exists(path)
  local fh = io.open(path, 'r')
  if fh then fh:close(); return true end
  return false
end

--[[
  Find the harness's results directory.

  Resource folders are commonly nested in bracketed category directories, so a plain
  join is not enough. `find` is used rather than guessing the layout.
]]
local function locate_results(root)
  local direct = root .. '/security-lab-exp/results'
  if exists(direct .. '/experiments.json') then return direct end

  local p = io.popen(string.format(
    'find %q -type d -name results -path "*security-lab-exp*" 2>/dev/null | head -5',
    root))
  if p then
    for line in p:lines() do
      if exists(line .. '/experiments.json') then p:close(); return line end
    end
    p:close()
  end
  return nil
end

local function main(argv)
  local root = argv[1]
  if not root or root == '' then
    io.write('usage: bash scripts/collect-lab-results.sh <path-to-server-resources>\n')
    io.write('   or: bash scripts/collect-lab-results.sh <path-to-security-lab-exp/results>\n')
    return 2
  end

  -- Accept either the resources root or the results directory itself.
  local results_dir
  if exists(root .. '/experiments.json') then
    results_dir = root
  else
    results_dir = locate_results(root)
  end

  if not results_dir then
    io.write(RED, 'could not find security-lab-exp/results/experiments.json under ',
      root, RESET, '\n')
    io.write('Has the harness run? See lab/experiments/README.md\n')
    return 1
  end

  io.write('found results in ', DIM, results_dir, RESET, '\n\n')

  os.execute('mkdir -p lab/results')

  local imported, problems = 0, 0
  local bundle

  for _, w in ipairs(WANTED) do
    local src = results_dir .. '/' .. w.file
    local body = read_file(src)
    if not body then
      if w.required then
        io.write(RED, 'MISSING ', RESET, w.file, '  (', w.what, ')\n')
        problems = problems + 1
      else
        io.write(YELLOW, 'absent  ', RESET, w.file, DIM, '  (', w.what,
          ' -- not produced yet)', RESET, '\n')
      end
    else
      -- Validate before importing. A file that does not parse must not become
      -- "the evidence".
      local decoded, err = J.decode(body)
      if not decoded then
        io.write(RED, 'CORRUPT ', RESET, w.file, '  ', tostring(err), '\n')
        problems = problems + 1
      else
        local ok, werr = write_file('lab/results/' .. w.file, body)
        if not ok then
          io.write(RED, 'FAILED  ', RESET, w.file, '  ', tostring(werr), '\n')
          problems = problems + 1
        else
          io.write(GREEN, 'imported', RESET, ' ', w.file,
            DIM, ('  (%d bytes)'):format(#body), RESET, '\n')
          imported = imported + 1
          if w.file == 'experiments.json' then bundle = decoded end
        end
      end
    end
  end

  if not bundle then
    io.write('\n', RED, 'no usable experiment results imported', RESET, '\n')
    return 1
  end

  -- ---- report what is unblocked -------------------------------------------
  io.write('\n', string.rep('-', 62), '\n')

  local concluded, blocked, inconclusive = {}, {}, {}
  for _, r in ipairs(bundle.results or {}) do
    if r.status == R.CONCLUDED then
      concluded[#concluded + 1] = r
    else
      inconclusive[#inconclusive + 1] = r
      if r.blocks then blocked[#blocked + 1] = r end
    end
  end

  io.write(('%d experiment(s) recorded: %s%d concluded%s, %d not\n')
    :format(#(bundle.results or {}), GREEN, #concluded, RESET, #inconclusive))

  if #concluded > 0 then
    io.write('\n', GREEN, 'CONCLUDED', RESET, '\n')
    for _, r in ipairs(concluded) do
      io.write(('  %-9s %-12s %s\n')
        :format(r.id, tostring(r.tag), tostring(r.finding)))
    end
  end

  if #inconclusive > 0 then
    io.write('\n', YELLOW, 'NOT CONCLUDED -- re-run these', RESET, '\n')
    for _, r in ipairs(inconclusive) do
      io.write(('  %-9s %s\n'):format(r.id, tostring(r.reason)))
    end
  end

  io.write('\n', string.rep('-', 62), '\n')
  if #blocked > 0 then
    -- Naming what stays blocked matters more than celebrating what passed: it is
    -- what stops someone filling the gap with a guessed threshold.
    io.write(RED, 'STILL BLOCKED', RESET, '\n')
    for _, r in ipairs(blocked) do
      io.write(('  %-9s blocks %s\n'):format(r.id, tostring(r.blocks)))
    end
    io.write('\nA hypothesis may not become a threshold (CLAUDE.md §5). Re-run rather\n')
    io.write('than guessing. See docs/LOCAL_SESSION.md §3 for what each unblocks.\n')
  else
    io.write(GREEN, 'nothing left blocked by an experiment', RESET, '\n')
    io.write('Next: write the knowledge/research entries, then implement what they\n')
    io.write('unblock (docs/LOCAL_SESSION.md §3).\n')
  end

  io.write('\nimported ', tostring(imported), ' file(s) into lab/results/')
  if problems > 0 then io.write(RED, ('  (%d problem(s))'):format(problems), RESET) end
  io.write('\nCommit them: they are evidence.\n')

  return problems == 0 and 0 or 1
end

os.exit(main({ ... }))

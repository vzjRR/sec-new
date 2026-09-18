--[[
  security-forensics / logic / investigation.lua

  PURE LUA. Assembles an incident, its detections and its telemetry into a bundle a
  human can review.

  ---------------------------------------------------------------------------
  THE TEST THIS MODULE MUST PASS (agents/FORENSICS_ENGINEER.md):

    Given an incident id, a human can reconstruct
      * what happened, and when
      * what was OBSERVED versus what was CLAIMED
      * which detector VERSIONS concluded what
      * what benign explanations were considered, and why they were rejected
      * what data is MISSING

  The last two are the ones that get skipped in practice, and they are the ones that
  make the difference between evidence and an accusation. So this module refuses to
  produce a bundle that omits them silently -- it reports their absence as a
  completeness problem instead.
  ---------------------------------------------------------------------------
]]

local function sec_require(key, path)
  if SecLab and SecLab[key] then return SecLab[key] end
  return require(path)
end

local timeline_lib  = sec_require('timeline', 'logic.timeline')
local detection_lib = sec_require('detection', 'logic.detection')

local M = {}

--[[
  Build an investigation bundle.

  @param incident  an incident instance (logic/incident.lua)
  @param records   telemetry records relevant to it
  @param opts      { dropped_n, store_complete, store_note }
  @return bundle table
]]
function M.build(incident, records, opts)
  assert(type(incident) == 'table' and incident.summary, 'investigation: incident required')
  opts = opts or {}

  local tl = timeline_lib.build(records or {}, {
    correlation_id = nil,               -- the caller pre-filters; see §note below
    dropped_n      = opts.dropped_n,
  })
  local tl_complete, tl_reason = timeline_lib.is_complete(tl)
  local trust = timeline_lib.trust_summary(tl)
  local summary = incident:summary()

  -- Detections, with the caps that were applied. A capped confidence is part of the
  -- story: it says the evidence did not support what the detector initially asked for.
  local detections = {}
  for _, d in ipairs(incident.detections) do
    detections[#detections + 1] = {
      detector_id      = d.detector_id,
      detector_version = d.detector_version,
      signal           = d.signal,
      severity         = d.severity,
      confidence       = d.confidence,
      confidence_requested = d.confidence_requested,
      confidence_caps  = d.confidence_caps,
      trust_basis      = d.trust_basis,
      sources          = d.sources,
      measurements     = d.measurements,
      explanation      = d.explanation,
      suppressed_by    = d.suppressed_by,
      evidence_refs    = d.evidence_refs,
    }
  end

  local bundle = {
    incident    = summary,
    status      = incident.status,
    history     = incident.history,
    detections  = detections,
    considered  = incident.considered,
    notes       = incident.notes,
    timeline    = tl,
    trust       = trust,
    completeness = {
      timeline_complete = tl_complete,
      timeline_note     = tl_reason,
      store_complete    = opts.store_complete,
      store_note        = opts.store_note,
    },
  }

  bundle.review = M.review(bundle)
  return bundle
end

--[[
  Assess whether the bundle is fit to support its own conclusion.

  Returns a list of problems, each with a severity. An empty list means the bundle is
  reviewable -- NOT that the player did anything.

  The checks are the ones that catch a bundle dressed up as evidence:
]]
function M.review(bundle)
  local problems = {}
  local function problem(sev, code, detail)
    problems[#problems + 1] = { severity = sev, code = code, detail = detail }
  end

  local inc = bundle.incident or {}
  local comp = bundle.completeness or {}

  -- 1. Missing data must block a conclusion, not be footnoted.
  if comp.timeline_complete == false then
    problem('high', 'incomplete_timeline',
      comp.timeline_note or 'the timeline has gaps')
  end
  if comp.store_complete == false then
    problem('high', 'incomplete_store',
      comp.store_note or 'the evidence store did not persist everything')
  end

  -- 2. A CONFIRMED incident with nothing observed is an accusation built on claims.
  local trust = bundle.trust or {}
  if inc.status == 'CONFIRMED' or bundle.status == 'CONFIRMED' then
    if (trust.observed_n or 0) == 0 then
      problem('critical', 'confirmed_without_observation',
        'this incident is CONFIRMED but its timeline contains no server-observed '
        .. 'records. A confirmation resting entirely on client claims is not evidence.')
    end
    if #(bundle.considered or {}) == 0 then
      problem('high', 'no_benign_causes_considered',
        'no benign explanation was recorded as considered. An investigator cannot '
        .. 'tell whether the obvious alternatives were ruled out or never examined.')
    end
  end

  -- 3. A single-detector incident above the claimed-only cap deserves a flag: it means
  --    one detector is carrying the whole conclusion.
  if (inc.distinct_detectors_n or 0) == 1 and (inc.confidence or 0) > 0.5 then
    problem('medium', 'single_detector_high_confidence',
      'one detector is carrying this conclusion. Correlation across independent '
      .. 'signals is Phase 5; until then treat this as a single-source finding.')
  end

  -- 4. Every detection must be explainable and versioned.
  for _, d in ipairs(bundle.detections or {}) do
    if type(d.explanation) ~= 'string' or #d.explanation < 30 then
      problem('high', 'unexplained_detection',
        string.format('%s has no usable explanation', tostring(d.detector_id)))
    end
    if not d.detector_version then
      problem('medium', 'unversioned_detection',
        string.format('%s has no version; this incident cannot be re-read in the '
          .. 'terms of the detector that produced it', tostring(d.detector_id)))
    end
  end

  -- 5. An incident with no detections at all.
  if (inc.detections_n or 0) == 0 then
    problem('medium', 'no_detections', 'this incident carries no detections')
  end

  table.sort(problems, function(a, b)
    local rank = { critical = 4, high = 3, medium = 2, low = 1 }
    local ra, rb = rank[a.severity] or 0, rank[b.severity] or 0
    if ra ~= rb then return ra > rb end
    return a.code < b.code
  end)

  return {
    reviewable = #problems == 0,
    problems   = problems,
    worst      = problems[1] and problems[1].severity or nil,
  }
end

--[[
  Render a bundle as plain text for a console or a ticket.

  Deliberately text: an investigator reading a disputed conclusion should not need the
  dashboard, and text survives being pasted into an email. Charter §17 keeps the
  dashboard minimal and late, so this is the primary human-facing output for now.
]]
function M.render(bundle)
  local L = {}
  local function line(fmt, ...)
    L[#L + 1] = select('#', ...) > 0 and string.format(fmt, ...) or fmt
  end

  local inc = bundle.incident or {}
  line('INCIDENT %s', tostring(inc.id))
  line('  player      %s', tostring(inc.player_key))
  line('  status      %s', tostring(bundle.status or inc.status))
  line('  severity    %s', tostring(inc.severity))
  line('  confidence  %.2f  (%s)', inc.confidence or 0, tostring(inc.confidence_basis))
  line('')

  local t = bundle.trust or {}
  line('TRUST BASIS')
  line('  observed %d · claimed %d — %s',
    t.observed_n or 0, t.claimed_n or 0, tostring(t.note))
  line('')

  line('DETECTIONS (%d)', #(bundle.detections or {}))
  for _, d in ipairs(bundle.detections or {}) do
    line('  %s v%s — %s [%s] confidence %.2f%s',
      tostring(d.detector_id), tostring(d.detector_version), tostring(d.signal),
      tostring(d.severity), d.confidence or 0,
      d.suppressed_by and (' SUPPRESSED by ' .. d.suppressed_by) or '')
    line('      %s', tostring(d.explanation))
    for _, c in ipairs(d.confidence_caps or {}) do
      -- Surfacing the cap matters: it says the evidence did not support the
      -- detector's own initial assessment.
      line('      capped (%s -> %.2f): %s',
        tostring(c.cap), c.limit or 0, tostring(c.reason))
    end
  end
  line('')

  line('BENIGN CAUSES CONSIDERED (%d)', #(bundle.considered or {}))
  for _, c in ipairs(bundle.considered or {}) do
    line('  [%s] %s — %s',
      c.ruled_out and 'ruled out' or 'OPEN', tostring(c.explanation), tostring(c.reason))
  end
  line('')

  local tl = bundle.timeline or {}
  local st = tl.stats or {}
  line('TIMELINE  %d record(s), span %s ms, %d gap(s)',
    st.records_n or 0, tostring(st.span_ms), st.gaps_n or 0)
  for _, e in ipairs(tl.entries or {}) do
    if e.kind == 'gap' then
      line('  --- GAP: %d record(s) missing (%s ms) ---',
        e.missing_n or 0, tostring(e.duration_ms))
    else
      local r = e.record or {}
      line('  %8s  %-12s %-22s %s',
        tostring(r.mono), tostring(r.category), tostring(r.event), tostring(r.trust))
    end
  end
  line('')

  --[[
    Rendering must never throw. This function is called while someone is reviewing a
    disputed conclusion -- the worst possible moment for a nil index -- so every
    field is treated as possibly absent, and a bundle with no review block says so
    rather than crashing.
  ]]
  local rev = bundle.review or {}
  local problems = rev.problems or {}
  if rev.reviewable == true then
    line('REVIEW: no completeness problems found')
  elseif rev.reviewable == nil and #problems == 0 then
    line('REVIEW: not assessed (no review block on this bundle)')
  else
    line('REVIEW: %d problem(s), worst = %s', #problems, tostring(rev.worst))
    for _, p in ipairs(problems) do
      line('  [%s] %s: %s',
        tostring(p.severity), tostring(p.code), tostring(p.detail))
    end
  end

  return table.concat(L, '\n')
end

--[[
  DUAL EXPORT -- see docs/ARCHITECTURE.md §3.2 "Module loading".
]]
SecLab = SecLab or {}
SecLab.investigation = M

return M

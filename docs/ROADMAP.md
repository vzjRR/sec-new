# ROADMAP

Status as of 2026-09-18. Tiers per `TESTING_METHODOLOGY.md` §1.

---

## Legend

`DONE` verified in Tier A · `PENDING-B` implemented, awaiting lab verification ·
`BLOCKED` waiting on an experiment · `TODO` not started

---

## Phase 0 — Discovery · **DONE**

`docs/ENVIRONMENT_AUDIT.md`. Established the three constraints, the verified native and
event surface, the permissive ConVar defaults, and the FXServer license blocker.

## Phase 1 — Foundation · **DONE (Tier A)** / **PENDING-B**

| Item | Status |
| --- | --- |
| Repository structure | DONE |
| `CLAUDE.md` | DONE |
| Architecture + model docs | DONE |
| Agent charters | DONE |
| Configuration system (typed, bounded, validated) | DONE |
| LAB/PRODUCTION mode (fails closed) | DONE |
| Structured logging | DONE |
| ConVar posture auditor | DONE |
| `security-core` resource + manifest | PENDING-B |
| **Resource starts successfully** | **PENDING-B — the Phase 1 exit criterion** |

## Phase 2 — Telemetry · **core DONE (Tier A)** / **PENDING-B**

| Item | Status |
| --- | --- |
| Versioned schema + validator | DONE |
| Injected clock with regression clamping | DONE |
| Envelope builder | DONE |
| Normalizers: weapon damage, explosion, entity, lifecycle, network, movement, aim | DONE |
| Bounded ring buffer with drop counting | DONE |
| Event adapters | PENDING-B |
| Pollers | PENDING-B |
| Identity resolution (QBCore `citizenid`) | PENDING-B |
| Sinks: memory, stdout, jsonl | PENDING-B (jsonl gated on EXP-008) |
| **End-to-end demonstration** (charter §26) | **PENDING-B** |

Charter §26 requires proving `FiveM → telemetry → normalized → storage → retrieval →
investigation output` for a **single** event type before widening coverage. That
demonstration is the next Tier B milestone.

## Phase 3 — Forensics · **DONE (Tier A)**

| Item | Status |
| --- | --- |
| `DetectionResult` type with the confidence policy **enforced in code** | DONE |
| Incident model + lifecycle state machine | DONE |
| Gap-aware timeline assembly | DONE |
| Deterministic JSON codec (encoder + strict decoder) | DONE |
| Evidence store: append-only, accountable, integrity digest | DONE |
| Investigation bundle + review + text render | DONE |

Three properties are worth noting, because they turn documented policy into
mechanism rather than prose:

- **Confidence caps are applied by construction.** `detection.new()` clamps a
  claimed-only detection to 0.5 and anything built on an uncharacterised native
  (EXP-001, EXP-002) to 0.3, records the original request, and names the blocking
  experiment. A detector cannot claim more than its evidence supports even if its
  author wants to.
- **The incident lifecycle refuses to erase mistakes.** `CONFIRMED → DISMISSED` is
  not an allowed transition; withdrawing a confirmation goes through `RESOLVED` with
  a recorded reason. `CONFIRMED` and `DISMISSED` both require a stated basis.
- **Incident confidence is `max`, not a sum.** Combining confidences requires arguing
  independence, which is Phase 5 work. Until then `max` is the honest answer and the
  summary says so.
- **Loss is accounted for at every layer.** The ring buffer counts drops, the timeline
  surfaces `seq` gaps as first-class entries, the store counts encode and backend
  failures, and the investigation `review()` refuses to call a bundle reviewable while
  any of them is non-zero. A store reporting "12 records" after 3 failed writes would
  be worse than no store.
- **`review()` refuses to bless an unsupportable conclusion.** A `CONFIRMED` incident
  whose timeline contains no server-observed record is flagged *critical*: a
  confirmation resting entirely on client claims is not evidence. A `CONFIRMED`
  incident with no benign cause recorded as considered is flagged too, because an
  investigator cannot otherwise tell whether the alternatives were ruled out or never
  examined.

## Phase 4 — First detectors · partly **BLOCKED**

Shipping order by defensibility (`DETECTION_MODEL.md` §7):

| # | Detector | Status |
| --- | --- | --- |
| 1 | `server.posture` | logic **DONE**; wiring as a detector TODO |
| 2 | `events.contract` | BLOCKED on EXP-006 |
| 3 | `entity.rate` | TODO |
| 4 | `combat.dead_shooter` | BLOCKED on EXP-007 |
| 5 | `movement.plausibility` | TODO — needs the full legitimate-cause list |
| 6 | `combat.sequence` | BLOCKED on EXP-002 |
| 7 | `aim.*` | **BLOCKED on EXP-001** |

## Phase 5 — Correlation · **TODO**
Multi-signal `RiskAssessment` with argued independence and documented weights.

## Phase 6 — Lab automation · **TODO**
Scenario runner: start, collect, record, compare expected vs actual, report.

## Phase 7 — Dashboard · **TODO**
Phase 1 scope only: server status, player list, recent telemetry, recent detections,
incident list, incident detail. No advanced analytics.

## Phase 8 — Hardening · **TODO**
Resource restart · server restart · reconnect · high player counts · telemetry spikes ·
malformed input · storage failure · missing dependencies · config errors.

---

## The critical path

```
EXP-004 (qb-core version) ─┐
EXP-008 (io availability)  ├─▶ Phase 2 end-to-end demo ─▶ Phase 3 forensics
Phase 1 boot verification ─┘                                     │
                                                                  ▼
EXP-006 (event inventory) ─────────────────────▶ detector 2 ─▶ Phase 5
EXP-007 (isdead timing)  ─────────────────────▶ detector 4
EXP-002 (weaponDamage)   ─────────────────────▶ detector 6
EXP-001 (camera natives) ─────────────────────▶ detector 7  ◀── the aim work
EXP-003 (peer stats)     ─────────────────────▶ detectors 5, 6 thresholds
```

**Everything now waits on the lab.** No further Tier-A work unblocks aim or combat
detection; only measurement does.

## Next actions

**Owner (Tier B, needs your PC):**
1. Start `security-core` and `security-telemetry` on the lab server; confirm boot and
   `security:status` output. This is the Phase 1 exit criterion.
2. Run `EXP-004` and `EXP-008` — both are quick and both gate Phase 2 completion.
3. Then `EXP-001` and `EXP-002`, which unblock the aim and combat work.

**Tier A (can proceed without the lab):**
1. ~~Phase 3 forensics~~ — **done**: detection type, incident lifecycle, timeline,
   JSON codec, evidence store, investigation export.
2. Wire `server.posture` as a formal detector emitting `DetectionResult`s.
3. Build the fixture replay harness so Tier B captures become regression tests.
4. Write the `detectors/*/` design specs for detectors 2–5.

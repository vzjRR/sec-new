# Detector design specifications

**These are specs, not code.**

FiveM resources cannot include files from outside their own folder, so detector
*implementations* live in `resources/[vzjrr-security]/security-detectors/logic/`. These
directories hold each detector's **design specification**, which per charter §18 must
exist before an implementation.

Keeping them separate means a design can be reviewed on its merits — particularly its
false-positive analysis — without reading Lua.

## Required sections

| Section | Why it is required |
| --- | --- |
| Objective | What behaviour, in one sentence |
| Telemetry consumed | Categories, events, measurements, and their **trust levels** |
| Signal definition | The precise computation |
| Thresholds + justification | A number with no justification is a guess |
| Confidence model | Including the caps from `DETECTION_MODEL.md` §3 |
| False-positive analysis | Every benign cause, and how it is handled or why it is not |
| Performance budget | Expected cost |
| Scenarios | Lab scenario IDs, **including the legitimate comparison** |
| Blockers | Experiments that must complete first |
| Status | design / implemented / verified, and in which tier |

A spec missing the false-positive analysis is not reviewable, and the detector does not
get implemented.

## Domains

| # | Spec | Status |
| --- | --- | --- |
| 1 | [`server/POSTURE-AUDIT.md`](server/POSTURE-AUDIT.md) | **implemented and wired** (Tier A) |
| 2 | [`events/EVENT-CONTRACT.md`](events/EVENT-CONTRACT.md) | design — blocked on EXP-006 |
| 3 | [`entities/ENTITY-RATE.md`](entities/ENTITY-RATE.md) | design — **not experiment-blocked** |
| 4 | [`combat/DEAD-SHOOTER.md`](combat/DEAD-SHOOTER.md) | design — blocked on EXP-007 |
| 5 | [`movement/MOVEMENT-PLAUSIBILITY.md`](movement/MOVEMENT-PLAUSIBILITY.md) | design — highest FP risk |
| 6 | `combat/` sequence statistics | not started — blocked on EXP-002 |
| 7 | `aim/` | not started — **blocked on EXP-001** |
| — | `economy/` | not started — blocked on EXP-006 |
| — | `player-state/` | not started |

### What the specs are actually for

Reading them in order, the pattern is deliberate: each one's longest section is its
**false-positive analysis**, and the further down the list a detector sits, the longer
that section gets. `movement.plausibility` has nine scenarios of which **eight are
legitimate cases** — that ratio is the honest reflection of where the difficulty lies.

Two framing decisions came out of writing them and are worth knowing before reading:

- `movement.plausibility` detects **unexplained** displacement, not "impossible"
  movement. An impossible displacement and a lag spike are identical in the data, so
  "impossible" would be a claim the data cannot support. It walks an attribution ladder
  and fires only on what no known cause explains — including a rung for *our own
  sampler having stalled*, because treating a late poll as a teleport would manufacture
  detections from our own scheduling.
- `combat.dead_shooter` deliberately does **not** use `weaponDamageEvent.damageTime`,
  so `EXP-002` does not block it. It uses our own observed arrival time, which needs no
  characterisation.

`server/` is an addition to the original structure. The charter permits adjusting the
layout where inspection shows something better, and the posture audit needed a home: it
is a real detector, but its subject is the server rather than a player.

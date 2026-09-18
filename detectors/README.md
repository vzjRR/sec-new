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

| Directory | Scope | First detector |
| --- | --- | --- |
| `server/` | The server's own configuration and posture | `server.posture` — **implemented** |
| `events/` | Net-event contracts | `events.contract` (EXP-006) |
| `entities/` | Entity creation and lifecycle | `entity.rate` |
| `movement/` | Position and velocity plausibility | `movement.plausibility` |
| `combat/` | Damage claims, engagement statistics | `combat.dead_shooter` (EXP-007) |
| `aim/` | Camera and target acquisition | **blocked on EXP-001** |
| `economy/` | Money, items, jobs | blocked on EXP-006 |
| `player-state/` | Health, armour, weapon plausibility | — |

`server/` is an addition to the original structure. The charter permits adjusting the
layout where inspection shows something better, and the posture audit needed a home: it
is a real detector, but its subject is the server rather than a player.

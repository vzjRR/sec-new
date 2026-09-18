# `movement.plausibility` — unexplained displacement

- **Status:** design. Not experiment-blocked, but **highest false-positive risk in the
  project** and therefore last among the non-aim detectors.
- **Planned order:** detector #5
- **Version:** 1 (planned)

## Objective

Detect displacement that cannot be attributed to any known legitimate cause.

Note the framing. Not "impossible movement" — **unexplained** movement. That difference
is the design.

## Why "unexplained" and not "impossible"

An impossible displacement and a lag spike are **identical in the data**. So are a
teleport script, a garage entry, an interior transition, a respawn, a revive, a bucket
change, and an admin moving a player.

A detector that outputs "impossible" is making a claim it cannot support from the data
available. A detector that outputs "a displacement I could not attribute to a known
cause" is making a claim that is exactly as strong as the evidence, and is still
actionable — it tells an investigator where to look.

This reframing is the single most important decision in this spec. Shipping a naive
`distance / time > limit` check would generate false positives on a live server within
minutes, and each one costs more than a missed cheat
(`docs/FALSE_POSITIVE_POLICY.md` §1).

## Telemetry consumed

| Source | Trust |
| --- | --- |
| `GET_ENTITY_COORDS`, `GET_ENTITY_VELOCITY`, `GET_ENTITY_SPEED` | **observed** |
| `GET_ENTITY_HEADING`, `IS_PED_RAGDOLL` | **observed** |
| `GET_VEHICLE_PED_IS_IN`, `IS_PED_IN_ANY_VEHICLE`, vehicle model | **observed** |
| `GET_PLAYER_ROUTING_BUCKET`, `onPlayerBucketChange` | **observed** |
| `GET_ENTITY_COLLISION_DISABLED` | **observed** |
| Ping, packet loss, RTT variance, `stale_ms` | **observed** |
| `HasPermission`, `GetPermission` | **framework** |
| `respawnPlayerPedEvent`, `playerJoining`, scope events | **observed** |
| Sample interval from our monotonic clock | **observed** |

## Signal definition

Between consecutive movement samples for one `player_key`:

1. Compute `displacement_m` and `interval_ms` (from `mono`, never `ts`).
2. Derive `implied_speed_mps`.
3. Compare against a **context-specific** plausible maximum: on foot, in a vehicle of
   that class, in the air, ragdolling, falling.
4. If exceeded, walk an **attribution ladder** (below). If any rung attributes it, record
   an attributed transition and do **not** fire.
5. Fire only on repetition: `min_events_n` unattributed excesses within a window.

### The attribution ladder

Checked in order; the first match explains the displacement:

| Rung | Evidence |
| --- | --- |
| Bucket change | `onPlayerBucketChange` within the interval → continuity invalid |
| Respawn / revive | `respawnPlayerPedEvent`, or health recovering from zero |
| Reconnect / join | `playerJoining` within the interval |
| Admin authority | `HasPermission` at an admin level |
| Network | concurrent ping / loss / RTT variance sufficient to explain the gap, allowing for `stale_ms` |
| Vehicle physics | in a vehicle whose class permits it; airborne; towed; ragdolling |
| Known teleport resource | a resource-attributed transition, if such telemetry is available |
| Sample gap | `interval_ms` far above the configured poll interval → the sampler stalled, so nothing can be concluded |

**The last rung matters and is easy to forget.** If the sampler itself was late, the
interval is not evidence of anything. Treating a stalled poller as a teleport would
manufacture detections from our own scheduling.

## Thresholds and justification

| Parameter | Approach |
| --- | --- |
| Plausible max speed per context | From the game's own vehicle data and observed on-foot maxima — **measured on the lab**, not taken from a wiki. |
| `min_events_n` | ≥3. A single sample pair is never enough: polling has gaps, and one anomaly is a sample, not a pattern. |
| Network allowance | Scaled from observed RTT variance, not a fixed grace. |

No threshold ships without a measured baseline. An estimate here becomes an accusation.

## Confidence model

| Condition | Confidence |
| --- | --- |
| Repeated unattributed excess, network nominal, no authority | **0.6** |
| Same, but network only partially explains it | **0.35**, `suppressed_by` recorded |
| Single unattributed excess | **does not fire** |
| Any ladder rung attributes it | **does not fire**; an attributed transition is recorded instead |

Capped at 0.6 for v1. Everything rests on sampled positions with known gaps, and the
attribution ladder is only as complete as our knowledge of the installed resources.
Higher confidence needs correlation with an independent signal — Phase 5.

## False-positive analysis

Every cause from `agents/MOVEMENT_ENGINEER.md`, with its handling:

| Cause | Handling |
| --- | --- |
| Admin teleport | Ladder: `HasPermission` |
| Teleport scripts (`qb-garages`, `qb-apartments`, `qb-houses`, `qb-interior`) | Ladder: resource attribution; enumerated by EXP-006 |
| Respawn, `qb-ambulancejob` revive | Ladder: respawn rung |
| Routing-bucket change | Ladder: continuity invalidated |
| Interior transitions | Ladder: resource attribution; otherwise a known-coordinate allowlist |
| Vehicle physics — ramps, explosions, tow, aircraft | Ladder: context-specific maxima by vehicle class |
| Network correction after loss | Ladder: network rung, honouring `stale_ms` |
| Reconnect | Ladder: join rung |
| Ragdoll, falling | Ladder: `IS_PED_RAGDOLL`, vertical-only displacement |
| Passenger in another player's vehicle | Context: driver vs passenger separated |
| **Our own sampler stalling** | Ladder: sample-gap rung |

**Unhandled and documented:** a sub-interval teleport that returns before the next
sample is invisible. That is inherent to polling (`docs/ARCHITECTURE.md` §10.6) and is
**not** to be papered over by raising the poll rate — that trades a real performance
cost for an illusion of coverage.

## Performance budget

The movement poller already exists (1 s default, ~7 native reads per player). This
detector adds only pure arithmetic per sample pair plus a bounded per-player window, so
its marginal cost is negligible. It introduces **no new polling**.

## Scenarios

| ID | Setup | Expected |
| --- | --- | --- |
| `MOVEMENT-001` | Repeated large unattributed displacement, network nominal | fire, ~0.6 |
| `MOVEMENT-002` | **Legitimate:** admin teleport | **no detection** |
| `MOVEMENT-003` | **Legitimate:** garage retrieval and apartment entry | **no detection** |
| `MOVEMENT-004` | **Legitimate:** death and respawn across the map | **no detection** |
| `MOVEMENT-005` | **Legitimate:** routing-bucket change | **no detection** |
| `MOVEMENT-006` | **Legitimate:** 300 ms ping with 5% loss and a stall | **no detection** |
| `MOVEMENT-007` | **Legitimate:** aircraft at altitude and speed | **no detection** |
| `MOVEMENT-008` | **Legitimate:** explosion launching a vehicle | **no detection** |
| `MOVEMENT-009` | **Legitimate:** reconnect | **no detection** |

Nine scenarios, of which **eight are legitimate cases**. That ratio is the honest
reflection of where the difficulty lies, and the detector does not ship until all eight
produce nothing.

## Blockers

No experiment strictly blocks implementation, but three things gate **enabling** it:

1. Measured plausible maxima per context (lab).
2. The installed-resource teleport inventory (`EXP-006`).
3. `EXP-003` — peer-statistics behaviour under induced latency and loss, to calibrate
   the network rung. Without it the most important ladder rung is guesswork.

# `combat.dead_shooter` — damage claims after a server-observed death

- **Status:** design. **BLOCKED on EXP-007.**
- **Planned order:** detector #4
- **Version:** 1 (planned)

## Objective

Detect `weaponDamageEvent` claims arriving from a player the server has already
observed as dead.

## Why this one before the interesting combat statistics

It is the **cleanest cross-reference available**: a client claim checked against an
independent server observation.

- The damage claim is `claimed` — the attacker chose every field in it.
- The death is `observed` — the server computed it from sync state and from
  `GET_ENTITY_HEALTH` / `metadata.isdead`.

A cheat can fabricate a damage claim. It cannot easily make the server's own view of its
health agree. That is exactly the shape `docs/TRUST_BOUNDARY.md` §4 requires for
confidence above the claimed-only cap, and it needs no statistical baseline — which is
why it precedes every distribution-based combat signal.

## Telemetry consumed

| Source | Trust |
| --- | --- |
| `weaponDamageEvent` (`sender`, `weaponType`, `hitGlobalIds`) | **claimed** |
| Event arrival time (our monotonic clock) | **observed** |
| `GET_ENTITY_HEALTH` on the sender's ped | **observed** |
| `metadata.isdead` | **framework** |
| `GET_PED_CAUSE_OF_DEATH`, `GET_PED_SOURCE_OF_DEATH` | **observed** |
| `respawnPlayerPedEvent` | **observed** |
| Network context (ping, loss, `stale_ms`) | **observed** |

The claim and the observation arrive as **separate records** joined by
`correlation_id`, never folded together (`logic/normalize.lua` header).

## Signal definition

For a damage claim from `player_key` at monotonic time `t`:

1. Find the most recent server-observed death for that player, at `t_death`.
2. If no respawn has been observed since `t_death`, compute `gap_ms = t - t_death`.
3. Fire when `gap_ms > grace_ms` and the claim count within the dead window exceeds
   `min_shots_n`.

## Thresholds and justification

| Parameter | Provisional | Justification |
| --- | --- | --- |
| `grace_ms` | **to be measured** | This is the whole experiment. It must cover the worst legitimate case: a shot genuinely fired *before* death whose event arrives after, delayed by network latency plus the server's own death-detection lag. |
| `min_shots_n` | 2 | One late claim is a race. A sequence is a pattern. |

**No number is shipped until EXP-007 measures the real distribution of "death observed"
versus "last legitimate claim arrives" under varying latency.** Picking `grace_ms`
by intuition would convert a plausible-sounding guess into false accusations against
players on bad connections — precisely what charter §21 forbids.

Expect `grace_ms` to need to be generous. The honest version of this detector fires only
on egregious cases, and that is fine.

## Confidence model

| Condition | Confidence |
| --- | --- |
| ≥2 claims, `gap_ms` beyond grace, network nominal | **0.7** |
| Same, but concurrent high latency or loss | **0.4**, and `suppressed_by` recorded |
| Claims well beyond grace (orders of magnitude), network nominal | **0.85** |

Capped below 0.9 permanently: the death is observed, but "observed" means *the server's
view of sync state*, which lags. A physics-grade certainty is not available here.

Basis is `claimed` + `observed`, so the 0.5 cap is lifted by the observed corroboration
— and **only** by it. If the death observation is missing for any reason, this detector
must fall back to ≤0.5 or not fire at all.

## False-positive analysis

The whole detector is a false-positive problem in disguise. Each cause and its handling:

| Cause | Handling |
| --- | --- |
| **A shot fired legitimately just before death** | The primary false positive. `grace_ms` exists solely for it, and its value comes from measurement. |
| **Latency delaying claim arrival** | Network-conditioned: suppress or downgrade when concurrent ping/loss could explain the gap. Note peer statistics are 10 s stale — consult `stale_ms` rather than assuming freshness. |
| **`metadata.isdead` set late or unreliably** | This is EXP-007. If it proves unreliable, the detector must use `GET_ENTITY_HEALTH` alone and say so. |
| **Revive / respawn not observed** | A missed respawn would make a living player look permanently dead — a catastrophic false positive. Mitigation: require a *recent* death, expire the dead window after a bounded time, and treat any health recovery as a respawn. |
| **`qb-ambulancejob` revive semantics** | Framework-specific; must be enumerated (EXP-006) and treated as a respawn signal. |
| **Death during a bucket change or reconnect** | Both invalidate continuity; the dead window is cleared. |
| **Vehicle/explosion damage resolving after the attacker's death** | `damageType` and `hasVehicleData` distinguish these; delayed-effect damage is exempt. |

**Unhandled and documented:** an attacker who only claims damage while alive is
invisible to this detector.

## Performance budget

O(1) per damage claim: one lookup of the player's last-death timestamp plus a counter.
No polling beyond the player-state sampling that already exists. Negligible.

## Scenarios

| ID | Setup | Expected |
| --- | --- | --- |
| `COMBAT-001` | Simulated damage claims well after an observed death, network nominal | fire, ~0.7–0.85 |
| `COMBAT-002` | **Legitimate:** a real shot fired ~1 frame before death | **no detection** |
| `COMBAT-003` | **Legitimate:** the same, under 300 ms ping and 5% loss | **no detection** |
| `COMBAT-004` | **Legitimate:** death, revive, then shooting | **no detection** |
| `COMBAT-005` | **Legitimate:** explosion damage resolving after the attacker died | **no detection** |
| `COMBAT-006` | **Legitimate:** death during a routing-bucket change | **no detection** |

`COMBAT-002` and `COMBAT-003` are the ones that decide whether this detector ships.

## Blockers

`EXP-007` — is `metadata.isdead` reliably set server-side at the moment of death, and
what is the real timing relationship between the server observing a death and the last
legitimate damage claim arriving? Both `grace_ms` and the confidence model depend on it.

`EXP-002` is **not** a blocker, because this detector deliberately does not use
`damageTime`: it uses our own observed arrival time, which needs no characterisation.

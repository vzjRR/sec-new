# COMBAT-ANALYST

## Status: partially **BLOCKED on EXP-002.**

## Mission
Build statistical combat features that distinguish skilled play from assisted or
impossible play.

## Primary data source
`weaponDamageEvent` — the richest per-shot primitive the server sees, and **cancellable**
(we never cancel it). Documented fields:

`sender` · `weaponType` · `weaponDamage` · `damageType` · `damageFlags` · `damageTime` ·
`hitComponent` · `hitGlobalId` · `hitGlobalIds[]` · `parentGlobalId` · `willKill` ·
`silenced` · `overrideDefaultDamage` · `hasVehicleData` · `tyreIndex` ·
`suspensionIndex` · `isNetTargetPos` · `localPos*` · `impactDir*` · `actionResult*`

Supporting: `explosionEvent`, `startProjectileEvent`, `GET_PED_SOURCE_OF_DAMAGE`,
`GET_PED_CAUSE_OF_DEATH`, `GET_ENTITY_HEALTH`, `GET_PED_ARMOUR`.

## The trust split — the core of this role
| Element | Trust |
| --- | --- |
| `sender` | **HIGH** — server-assigned |
| arrival time (our clock) | **OBSERVED** |
| every payload field | **LOW** — attacker-chosen |
| inter-arrival timing distribution | **DERIVED from observed** — the attacker does not control our clock |
| the target's actual position/health | **OBSERVED** via natives |

So the strong features are **timing distributions** and **cross-referenced geometry**,
not claimed values. A cheat can claim any hit; it is much harder to make the server's own
view of two players agree with a fabricated line of fire, and harder still to make an
inter-arrival distribution look human across hundreds of engagements.

## EXP-002 — the blocker
Unknown: `damageTime`'s clock base and unit; `hitGlobalId` vs `hitGlobalIds[]` semantics;
behaviour on miss vs hit; the undocumented fields `f104`, `f112`, `f112_1`, `f120`,
`f133`. Until measured, `damageTime` is recorded with a dimensionless `_n` suffix so no
detector can treat it as milliseconds.

## Feature candidates — HYPOTHESIS until validated
- inter-shot interval distribution per weapon (mean, variance, minimum, modality)
- hit/miss ratio conditioned on range, target motion and weapon
- `hitComponent` distribution (headshot share) conditioned on range and weapon
- engagement duration and target-switch intervals
- damage-per-second versus the weapon's server-side plausible maximum
- repeated identical engagement profiles
- **cross-check**: claimed hit vs server-observed distance between shooter and target
- **cross-check**: claimed damage vs the target's observed health delta

The last two are the most defensible in the whole project: they compare a claim against
an independent server observation.

## Design rules
1. Condition on context always: weapon, range, target motion, vehicle, network.
2. Never fire on one engagement. Distributions need samples.
3. `willKill` and `weaponDamage` are claims — an impossible claim proves tampering with
   the claim, which is a finding about the *event*, not proof about the player's aim.
4. NPC combat differs from player combat and must be separated.

## Anti-patterns
- `headshot_rate > X ⇒ cheating`
- Computing a "distance" from claimed `localPos*` and calling it observed
- Ignoring armour and `overrideDefaultDamage` when reasoning about damage

# RED-TEAM / LAB-SIMULATION ENGINEER

## Status: LAB only. Refused in PRODUCTION by two independent guards.

## Mission
Produce the **telemetry and conditions** a detector must recognise — using controlled
simulators, never real cheats.

## The boundary, stated plainly
**Build:** simulators that generate the relevant telemetry, malformed-but-locally-
generated inputs, reproducible scenarios, synthetic event injection in LAB, load and
spike generators, false-positive scenarios.

**Never build:** public cheat software or loaders, credential theft, malware, destructive
tooling, anything targeting other servers, anything to bypass commercial or public
anti-cheat, persistence or evasion mechanisms.

The distinction is purpose and blast radius: a simulator produces the *signal* a detector
consumes and runs only on a private lab server. A cheat produces an *advantage* and
works anywhere. When a behaviour must be studied, simulate the telemetry — do not build
the weapon.

## The two guards (charter §8)
1. **Runtime** — simulator entry points call `mode.require_lab()` and refuse loudly in
   PRODUCTION. Unknown capabilities are denied by default.
2. **Packaging** — simulators live in `lab/`, a separate resource set that is not part of
   the protection deployment. A PRODUCTION install does not contain the code.

Two guards because one is not enough for this particular footgun: the charter's own
warning is "never accidentally ship a simulator as part of production protection".

## Scenario format
Every scenario has an ID (`AIM-001`, `COMBAT-001`, `MOVEMENT-001`, `EVENT-001`,
`ENTITY-001`, `ECONOMY-001`) and states: objective · environment (always LAB) · setup ·
expected telemetry · expected detector · expected result · **legitimate comparison** ·
false-positive risks · cleanup · regression fixture.

The **legitimate comparison is mandatory**. A scenario that only shows a detector firing
on the bad case says nothing about its false-positive rate, and a detector validated
that way is a false-positive generator waiting for production.

## Planned first scenarios
| ID | Produces | Validates |
| --- | --- | --- |
| `EVENT-001` | net-event calls with wrong arity/type/frequency | `events.contract` |
| `ENTITY-001` | client entity creation bursts | `entity.rate` |
| `MOVEMENT-001` | displacement beyond plausible, plus a lag-spike comparison | `movement.plausibility` |
| `MOVEMENT-002` | **legitimate** teleport, admin move, respawn, bucket change | must NOT fire |
| `COMBAT-001` | damage claims after a server-observed death | `combat.dead_shooter` |
| `AIM-001` | scripted camera motion for **EXP-001 measurement**, not detection | characterisation |

`AIM-001` is a measurement scenario first. There is nothing to detect until EXP-001 says
what the camera natives do.

**When `AIM-001` becomes a detection scenario, it must reproduce SMOOTHED aim, not
instant snapping.** A real sample analysed in
`knowledge/research/R-005-external-cheat-sample-analysis.md` ships with configurable
smoothing, because instant snaps are obvious. A simulator that only generates snaps
would validate a detector against a threat that barely exists — and would produce a
detector that passes its own scenario while missing everyone who moved the slider.

## Anti-patterns
- A "realistic" cheat when a telemetry generator would do
- A simulator outside `lab/`
- A scenario without a legitimate comparison
- Anything that would function on a server other than this lab

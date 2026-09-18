# PERFORMANCE ENGINEER

## Status: **BLOCKED — nothing has run inside FXServer yet.** All figures are intent.

## Mission
Keep the platform's cost low enough that an operator never has a reason to remove it.
Performance is a security property: an uninstalled anti-cheat detects nothing.

## Owns
- `docs/PERFORMANCE_BUDGET.md`
- poll-interval justifications in `lib/config.lua`
- the measurement plan and the back-out thresholds

## Design rules already enforced
1. **Events over polling.** Event cost scales with activity; polling scales with player
   count regardless.
2. **Lowest useful frequency**, justified per poller, bounded min and max, validated at
   boot — a mistyped `0` cannot busy-loop the server.
3. **Bounded memory everywhere.** The ring buffer has a hard cap and counts drops. A
   telemetry spike is what a mass-abuse incident looks like; the anti-cheat must not be
   what takes the server down during an attack.
4. **Hot path appends only.** Queries, joins and aggregation happen offline in a
   different process.

## The interval that needs the most scrutiny
The **aim poller** at 500 ms. At 64 players that is 128 sampling operations per second,
each doing ~5 native calls — the most expensive thing in the design, and its interval is
**not justified by measurement**. EXP-001 must establish how often
`GET_PLAYER_CAMERA_ROTATION` actually changes; polling faster than that is waste and
slower loses detail. Until then it is explicitly a placeholder.

The **network poller** is the opposite case and shows the rule working: peer statistics
refresh only every 10 s server-side, so the interval is 10 s and the config floor is 5 s.

## Storage is the unsolved problem
Rough order for 64 players over one hour: movement ~80 MB, aim ~135 MB. **That is too
much for continuous production use.** Mitigations, in preference order:
1. high-rate capture in LAB only
2. **detector-driven sampling** — dense only for players with an open incident
3. rotation and compression, short raw retention, longer evidence retention
4. store derived windows instead of raw samples once baselines exist

(2) is the architecturally interesting one and belongs in Phase 4.

## Measurement plan (Tier B)
FiveM's built-in profiler per resource · `GetGameTimer()` deltas around adapter bodies,
emitted as `system` telemetry · resource memory over a 4-hour session · ring-buffer
`dropped_n` as the saturation signal · baseline tick with resources stopped vs started.

## Back-out thresholds
> 0.5 ms average per server tick · unbounded memory growth over 4 hours · ring-buffer
drops during normal play · any measurable client frame-time impact (there should be none
— there is no client component).

## Anti-patterns
- Publishing a cost figure that was not measured
- Raising a poll rate to fix a detection gap that is really a reasoning gap
- Aggregating in the game process

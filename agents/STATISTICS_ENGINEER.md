# STATISTICS / BASELINE ENGINEER

## Status: **BLOCKED — no real telemetry exists yet.** Nothing to baseline.

## Mission
Replace threshold guessing with distributions, variance and population baselines.

## Why this role exists
The charter is explicit that `accuracy > X ⇒ cheating` is the reasoning to avoid. The
replacement is not a cleverer threshold; it is a different question:

> Not "is this value high?" but "is this value, **in this context**, unusual for **this
> player** relative to **this population**, and does the **pattern repeat**?"

## What it will own
- per-player baselines keyed on `QB:citizenid`
- population baselines per server
- context conditioning: weapon, range, target motion, vehicle, network, time of day
- variance and consistency metrics
- confidence calibration — turning a statistical distance into a defensible probability

## The central hypothesis of the project
**Skill shows as high performance with natural variance. Assistance often shows as
performance with too little variance.** A human's results shift with fatigue, range,
target difficulty and engagement type; a machine's often do not.

This is a **HYPOTHESIS**, clearly labelled. It is plausible, it is the most promising
avenue available given C1, and it may turn out to be wrong or to have a much smaller
effect size than hoped. It must be tested against real data from both skilled legitimate
players and lab simulations before any detector relies on it.

## Design rules
1. **A baseline needs enough samples**, and the minimum must be stated and enforced.
   Below it, the answer is "unknown", not a low score.
2. **Cold start is a real problem.** A new player has no baseline. Never treat "no
   history" as suspicious — that punishes newcomers, the worst possible false positive.
3. **Population baselines are per server.** A hardcore PvP server's distribution is not
   a roleplay server's.
4. **Document every weight and its justification** in `knowledge/decisions/`. Charter
   §11 forbids arbitrary score arithmetic.
5. **Independence must be argued** before combining signals. Two features derived from
   the same `weaponDamageEvent` fields are not independent, and combining them inflates
   confidence on a single piece of evidence.
6. **Drift is expected.** Baselines are re-estimated; a stale baseline produces false
   positives as the population changes.

## Prerequisites
Phase 2 running on the lab, then weeks of real telemetry including known-legitimate
skilled players. Until then this role designs the framework and writes the tests; it
does not ship numbers.

## Anti-patterns
- Picking a threshold from a forum post, a video, or another anti-cheat
- Summing unjustified scores into a "cheat score"
- Treating a new player's absent baseline as a signal
- Reporting a z-score as if it were a probability of cheating

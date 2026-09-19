# AIM-DETECTION-ENGINEER

## Status: **BLOCKED on EXP-001.** No aim detector may ship before it completes.

## Mission
Detect abnormal aiming and target-acquisition behaviour using **server-authoritative**
data only.

## The good news
Aim telemetry does **not** require a trusted client agent. These are server natives
under OneSync (`docs/ENVIRONMENT_AUDIT.md` §7.2):

| Native | Returns |
| --- | --- |
| `GET_PLAYER_CAMERA_ROTATION` (`0x433C765D`) | `Vector3` — documented: "used server side when using OneSync" |
| `GET_PLAYER_FOCUS_POS` (`0x586F80FF`) | `Vector3` — camera position in the world |
| `IS_PLAYER_IN_FREE_CAM_MODE` (`0x1F14F2AC`) | `bool` |
| `GET_PED_DESIRED_HEADING` | `float` |

This removes the weakest link most aim-detection designs depend on. It is the single
most valuable finding in the audit.

## The blocker, stated precisely
**Nothing is known about how these natives behave.** Unmeasured: update rate, precision,
smoothing/interpolation, behaviour in first vs third person, in vehicles, during
cutscenes, while dead, and across routing buckets.

Building a detector now would convert a hypothesis into a rule, which charter §21
forbids and which would produce false accusations against real players. The 500 ms aim
poll interval currently in config is a **placeholder for data collection**, not a tuned
value, and is documented as such.

## EXP-001 — what it must answer
1. How often does the returned rotation actually change? (poll at 50/100/250/500/1000 ms)
2. What is its precision, and is it smoothed relative to true camera motion?
3. Does it differ between first and third person?
4. What does it return in a vehicle, during a cutscene, while dead, while free-cam?
5. How does it degrade under high ping and packet loss?
6. Does it lag the client's actual aim, and by how much?

Method: scripted known camera motions in LAB, with client-side ground truth recorded
separately for comparison.

## Candidate signals, once characterised — all HYPOTHESIS
- angular velocity distribution and its variance
- snap characteristics: time-to-target and overshoot on acquisition
- target-switch latency across sequential engagements
- correlation between camera direction and claimed hit geometry (this one is strong: it
  cross-references `observed` camera data against `claimed` hit data)
- tracking smoothness during target motion
- repeated identical acquisition profiles across engagements

## Evidence from a real sample (R-005)

A real external cheat sample was statically analysed
(`knowledge/research/R-005-external-cheat-sample-analysis.md`). Its aimbot ships with
**configurable smoothing** (`aimbot_smooth_enabled`, `aimbot_smooth_speed`), which
exists precisely because an instantaneous snap is obvious.

Three things follow:

- **A snap-magnitude detector would catch only the users who left smoothing off.** The
  naive signal is defeated by a slider the user has already been given.
- The sample's ESP features — two thirds of its surface — produce **no server-observable
  effect at all**, confirming that the aimbot's camera movement is the entire
  server-visible footprint of this class of tool.
- The adversary holds a dial trading effectiveness for stealth, so expect a
  *distribution* of behaviours across users rather than one signature, and expect the
  true-positive rate to decay as users turn it down.

## Design rules
1. **No single metric decides anything.** Not angular velocity, not snap time.
2. **Consistency, not peak.** A skilled human's aim varies with fatigue, range and
   target difficulty. Assisted aim often varies *too little*. Absence of variance is the
   interesting signal; a good shot is not. R-005 supports this: smoothed aim is
   *generated*, and generated motion tends to be more self-consistent than human motion.
   It remains a **HYPOTHESIS** until EXP-001 and real captures test it.
3. **Confidence capped at 0.3** for anything derived from these natives until EXP-001
   completes (`DETECTION_MODEL.md` §3).
4. **Network context mandatory.** Latency distorts every angular measurement.
5. **Controller vs mouse, and sensitivity differences, must be modelled** as benign
   causes before shipping.

## Anti-patterns
- Shipping a threshold from a video, a forum post, or another anti-cheat
- Treating a high headshot rate as aim assistance
- Trusting the claimed `localPos*`/`hitComponent` fields as geometry

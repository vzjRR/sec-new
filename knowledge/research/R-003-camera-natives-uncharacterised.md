# R-003 — Server camera natives exist but are uncharacterised

- **Date:** 2026-09-18
- **Role:** AIM-DETECTION-ENGINEER
- **Tag:** **HYPOTHESIS** — usable for aim detection, **untested**

## Claim
`GET_PLAYER_CAMERA_ROTATION`, `GET_PLAYER_FOCUS_POS` and `IS_PLAYER_IN_FREE_CAM_MODE`
are server natives (R-002, FACT). Whether they are *usable for aim detection* is a
hypothesis, because nothing is known about their behaviour.

## Unknown
- update rate — how often does the value actually change?
- precision, and whether it is smoothed or interpolated relative to true camera motion
- first-person vs third-person behaviour
- behaviour in a vehicle, during a cutscene, while dead, in free-cam
- lag relative to the client's actual aim
- degradation under high ping and packet loss

## Implication
1. **EXP-001 blocks all aim detection.** Charter §21 forbids turning a hypothesis into a
   detection rule; doing so here would produce false accusations against real players.
2. The current `poll.aim_ms = 500` default is a **placeholder for data collection**, not
   a tuned value. It is the most expensive poller in the design (§PERFORMANCE_BUDGET §3)
   and its interval is unjustified until this experiment runs.
3. Confidence for anything derived from these natives is **capped at 0.3**
   (`DETECTION_MODEL.md` §3) until characterised.
4. Phase 2 **records** aim samples. It does not reason about them. Recording is how
   EXP-001 gets its data.

## What would change this
EXP-001 results. If the natives turn out to be heavily smoothed or to update only once a
second, the whole aim approach needs rethinking rather than retuning — which is exactly
why the experiment precedes the detector.

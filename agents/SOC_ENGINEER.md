# SOC / DASHBOARD ENGINEER

## Status: Phase 7. Deliberately last.

## Mission
Give an operator a way to see server health, telemetry and incidents — and to reach a
defensible judgement.

## Why last
A dashboard over an unvalidated pipeline is a confidence machine: it makes
half-understood data look authoritative, and an operator will act on it. The data model,
the trust taxonomy and the incident lifecycle must be settled first, or the UI ends up
encoding decisions that were never made deliberately.

## Phase 1 scope — and nothing more
server status (mode, uptime, blind/state-aware, posture summary) · player list ·
recent telemetry · recent detections · incident list · incident detail with timeline.

Explicitly **not** in Phase 1: heatmaps, trend charts, anomaly scores, ML dashboards,
leaderboards of "most suspicious players".

## Display rules — these are the substance of this role
1. **Show the trust basis.** Every displayed measurement is marked `observed`,
   `claimed`, `derived` or `framework`. An operator must see at a glance which parts of a
   story the attacker controlled. Hiding this is how a dashboard turns a claim into a
   fact.
2. **Show gaps.** If the ring buffer dropped records, the timeline says so. Never draw a
   continuous line through missing data.
3. **Show confidence with its explanation.** Never a bare number. If the UI cannot fit
   the explanation, the UI is wrong, not the explanation.
4. **Show detector versions.** An incident from detector v1 must not be read in v3's
   terms.
5. **Show what was considered and rejected.** The benign explanations that were ruled out
   are part of the evidence.
6. **No verdict language.** "3 signals, confidence 0.62, network unexplained" — not
   "CHEATER". The UI must not imply an enforcement action the platform does not perform.
7. **No PII.** `player_key` only. Identifier resolution is a separate,
   access-controlled action with its own audit trail.

## Architecture
Reads the **offline** analysis store (`node:sqlite` over the JSONL), never the live game
process. The dashboard must not be able to add load to the server tick, and must keep
working when the game server is down — that is exactly when an operator wants to look.

## Anti-patterns
- A "suspicion leaderboard"
- A bare score with no explanation
- Querying the game process
- A one-click ban button (there is no enforcement layer, and the UI must not pretend)

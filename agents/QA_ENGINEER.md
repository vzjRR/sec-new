# QA / FALSE-POSITIVE ENGINEER

## Status: active. Owns the standard that gates every detector.

## Mission
Make false positives the project's primary quality metric, and prove every detector
against legitimate behaviour before it ships.

## Position
A false positive costs more than a missed detection. A missed cheat annoys players; a
false accusation loses a legitimate player, damages the server's reputation, and teaches
the operator to distrust the system — after which every true positive is discounted too.

## Owns
- `docs/FALSE_POSITIVE_POLICY.md`
- the legitimate-scenario suite and its fixtures
- `tests/legitimate/` and `tests/regression/`
- the gate: **zero detections on the legitimate suite** before a detector is enabled

## The legitimate suite (each needs a fixture)
skilled players · high ping · packet loss · FPS drops · controller input · mouse input ·
differing sensitivities · vehicle combat · NPC combat · legitimate teleport scripts ·
admin actions · interiors · cutscenes · resource restart · reconnect · server restart ·
routing-bucket change · respawn · revive.

## Testing rules this role enforces
1. **Assert on error messages, not just booleans.** `H.rejects(ok, errs, needle)` exists
   because a validation test that only checks `ok == false` keeps passing after it starts
   failing for an unrelated reason.
2. **Test the guards.** `check_no_enforcement.lua` self-tests before running, because its
   first version **silently passed everything** (an unescaped paren made the regex
   invalid) and a later version missed the `QBCore.Functions.Kick` dot form. A gate that
   cannot fail produces false confidence, which is worse than no gate.
3. **Test hostile input.** Normalizers get nil, empty tables, wrong types, NaN, infinity,
   and non-array values where arrays are expected. An adapter crash is a DoS against our
   own observability.
4. **Test that defaults are the documented defaults.** `test_posture.lua` asserts
   `sv_scriptHookAllowed` unset is *not* flagged — getting that backwards would fire on
   every correctly configured server.
5. **Fixtures are never rewritten to match new code.**
6. **Every dismissed incident becomes a fixture** in `knowledge/false-positives/`.

## Current state
162 unit tests, 29 files linted, guard self-test plus a 13-case behaviour matrix — all
Tier A. **The legitimate suite does not exist yet**, because it needs real captures from
the lab. That is the honest gap and the next QA priority once Phase 2 runs.

## Anti-patterns
- "We'll add false-positive tests later"
- A test that passes because nothing ran
- Measuring only the true-positive rate
- Shipping a detector whose false-positive rate is unknown

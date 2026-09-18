# `server.posture` — ConVar hardening audit

- **Status:** logic **implemented and unit-tested** (Tier A, 20 tests).
  Wiring as a formal `DetectionResult` emitter: TODO.
- **Implementation:** `resources/[vzjrr-security]/security-core/lib/posture.lua`
- **Decision record:** `knowledge/decisions/D-003-posture-audit-ships-first.md`
- **Version:** 1

## Objective

Report where the server's own configuration permits abuse that no behavioural detector
should have to catch.

## Why this is detector #1

The audit found that several FiveM security ConVars **default to the permissive
setting**. On a default server, clients may write their own player state bag, create
arbitrary entities, and request control of entities they do not own. A meaningful share
of "cheating" on such a server is *permitted by configuration*.

Detecting an abuse the server is configured to allow is strictly worse than disallowing
it. And uniquely among the planned detectors, this one has **zero false-positive risk
against players**: its findings are about the server, never accusations about a person.

## Telemetry consumed

| Source | Trust | Notes |
| --- | --- | --- |
| `GetConvar('onesync', …)` and 7 others | `observed` | Read by the adapter; a sentinel distinguishes "unset" from "set falsely" |

No player telemetry. No baseline. No history.

## Signal definition

Eight independent checks. Each returns pass, or a finding carrying `severity`, the
observed `detail`, an `impact` statement, and a copy-pasteable `remediation`.

| ID | ConVar | Fails when | Severity |
| --- | --- | --- | --- |
| POSTURE-001 | `onesync` | not `on` | critical |
| POSTURE-002 | `sv_scriptHookAllowed` | `true` | critical |
| POSTURE-003 | `sv_stateBagStrictMode` | not `true` | high |
| POSTURE-004 | `sv_entityLockdown` | not `strict`/`full` (`relaxed` reported) | high |
| POSTURE-005 | `sv_filterRequestControl` | `< 1` | medium |
| POSTURE-006 | `sv_authMinTrust` | `< 2` | medium |
| POSTURE-007 | `sv_authMaxVariance` | `> 4` | medium |
| POSTURE-008 | `sv_endpointPrivacy` | not `true` | low |

Findings are sorted worst-first, then by id, so output is stable across runs and
comparable as a fixture.

### `is_blind()` is deliberately separate

`onesync` not being `on` is not a hardening suggestion — it means the platform is
**structurally unable to observe** combat, aim or entities. A hardening gap is the
operator's judgement call; blindness is not, and it is reported as an error rather than
folded in with the advisory findings.

## Threshold justification

There are no tuned thresholds. Each check compares against the **documented hardened
value**, and each severity reflects what the permissive setting makes possible:

- **critical** — the platform cannot observe (`onesync`), or arbitrary client native
  execution is permitted (`sv_scriptHookAllowed`, which the official docs say "makes the
  server vulnerable to security issues")
- **high** — a direct abuse vector: writable player state, or arbitrary client entity
  creation
- **medium** — a weakened boundary: control requests, identity quality
- **low** — a player-privacy exposure rather than a cheat vector

## Confidence model

Confidence is **1.0** and that is legitimate here, unlike anywhere else in the project:
the finding is a direct read of server configuration, not an inference about behaviour.
There is nothing probabilistic about `sv_entityLockdown` being `inactive`.

## False-positive analysis

Against players: **none possible** — no player is named.

Against the operator, three real risks, all handled:

1. **`sv_scriptHookAllowed` unset must NOT be flagged**, because it genuinely defaults to
   `false`. Getting this backwards would fire on every correctly configured server. There
   is an explicit test for it.
2. **`sv_entityLockdown strict` can break resources** that legitimately create client
   entities. So `relaxed` is *reported with its trade-off explained* rather than treated
   as failure, and the remediation line mentions both options. The operator decides.
3. **A finding nobody understands gets ignored or disabled.** Tests assert every finding
   carries a substantive `impact` (> 40 chars) and a concrete `remediation`.

Ambiguity resolves toward reporting: an unparseable boolean (`"maybe"`) is treated as
not-hardened rather than silently passed.

## Performance budget

8 `GetConvar` reads at boot and every 300 s (configurable, min 60 s). Negligible. The
re-check exists because ConVars can change at runtime.

## Scenarios

| ID | Setup | Expected |
| --- | --- | --- |
| `POSTURE-001` | fully hardened `server.cfg` | 0 findings |
| `POSTURE-002` | stock `server.cfg` (nothing set) | ≥ 7 findings, worst = critical |
| `POSTURE-003` | `onesync off` | `is_blind() == true`, logged as an error |
| `POSTURE-004` | `sv_entityLockdown relaxed` | reported with the trade-off, not silent |

All four are covered by Tier A unit tests. Tier B should confirm that `GetConvar` returns
what is expected for unset variables on the target build — the adapter uses an `__unset__`
sentinel precisely because "unset" and "set to false" must stay distinguishable.

## Blockers

None. This is the only planned detector that is not waiting on an experiment.

## Remaining work

1. Emit findings as formal `DetectionResult`s once Phase 3 defines the type.
2. Add a `system`-category telemetry record per audit run so posture drift over time
   becomes visible in the evidence store.

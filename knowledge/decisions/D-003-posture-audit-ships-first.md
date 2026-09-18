# D-003 — The ConVar posture audit is the first detector

- **Date:** 2026-09-18
- **Role:** SECURITY-ORCHESTRATOR
- **Status:** accepted; logic implemented and unit-tested

## Decision
`server.posture` ships before any behavioural detector — before aim, combat, movement or
economy.

## Context
The project's motivation was aim assistance. The audit found (§7.7) that several FiveM
security ConVars **default to the permissive setting**:

| ConVar | Default | Consequence |
| --- | --- | --- |
| `sv_stateBagStrictMode` | `false` | Clients can write their own player state bag and owned entities' state |
| `sv_entityLockdown` | `inactive` | "Clients can create any entity" |
| `sv_filterRequestControl` | `0` | Unrestricted `REQUEST_CONTROL_EVENT` routing |
| `sv_authMinTrust` | `1` of 5 | Weakest identity providers accepted |
| `sv_authMaxVariance` | `5` of 5 | Identifiers expected to churn |

## Rationale
1. **A meaningful share of "cheating" on a default server is permitted by
   configuration.** Detecting an abuse the server is configured to allow is strictly
   worse than disallowing it.
2. **Zero false-positive risk against players.** It makes findings about the *server*,
   never accusations about a person. Nothing else in the project can say that.
3. **No baseline required.** Behavioural detectors need weeks of telemetry; this needs
   eight ConVar reads.
4. **It is the only detector that can ship before the experiments complete**, so it is
   the only way to deliver value now.
5. **It improves every later detector**, by removing the noise that permissive
   configuration generates.

## Implementation notes
Each of the 8 checks carries `severity`, the observed `detail`, an `impact` statement in
terms of *what becomes possible*, and a copy-pasteable `remediation` line. A finding an
operator cannot understand or act on will be ignored or disabled, so the tests assert
that every finding has a substantive impact and a concrete remediation.

`is_blind()` is deliberately separate from the findings: a hardening gap is the
operator's judgement call, but `onesync` not being `on` means the platform is
**structurally unable to observe** and must say so loudly rather than degrade silently.

## Consequences
- Operators may perceive the platform as "just a config checker" at first. Accepted: it
  is honest about what is verified.
- Some findings may conflict with a server's resource needs (`sv_entityLockdown strict`
  can break resources that create client entities). Hence `relaxed` is explained rather
  than dismissed, and every finding is advisory — the platform never changes a ConVar.

# FiveM Security Lab

A **defensive security research platform** for a private FiveM / FXServer laboratory.
Server-authoritative telemetry, explainable detection, and reconstructable evidence.

- **Owner:** vzjRR · **Framework:** QBCore (`qb-core`) · **Architecture:** `/TSU` + `/TSG`
- **Status:** Phase 1 foundation and Phase 2 telemetry core complete in CI.
  **Nothing has yet run inside FXServer** — see [Verification](#verification).

---

## What this is

An **observatory**, not an enforcement system. It records what happened, normalizes it,
reasons about it with explicit confidence, and produces evidence a human can
reconstruct.

The objective is not "an anti-cheat that bans people". It is a defensible, measurable,
explainable platform that identifies abnormal behaviour with strong evidence while
minimising false positives.

**There is no ban path, no kick path, and no event cancellation anywhere in the
codebase** — and a build gate (`scripts/check_no_enforcement.lua`) fails if one appears.

## Three measured constraints shape everything

| | Constraint | Consequence |
| --- | --- | --- |
| **C1** | 0 of 6,416 GTA natives and 360 of 943 Cfx natives are server-callable | **No client-side component.** Every signal is server-observed. |
| **C2** | FXServer needs a license key and cannot boot in CI; vanilla Lua 5.4 lacks CfxLua extensions | **Pure logic behind thin adapters** — the only shape that can be tested. |
| **C3** | Evidence bridges the two test tiers | Append-only JSONL, replayable as CI fixtures. |

Evidence for each is in [`docs/ENVIRONMENT_AUDIT.md`](docs/ENVIRONMENT_AUDIT.md).

One finding is worth surfacing here: **`GET_PLAYER_CAMERA_ROTATION` is a server native
under OneSync.** Aim telemetry does not require a trusted client agent — which removes
the weakest link most aim-detection designs depend on.

## Layout

```
docs/          architecture, models, policies, the environment audit
agents/        18 role charters (/TSU + /TSG)
resources/[vzjrr-security]/
  security-core/        boot, config, LAB/PRODUCTION mode, logging, ConVar posture
  security-telemetry/   event adapters, pollers, normalization, sinks
  security-detectors/   detector registry (Phase 4)
  security-forensics/   incidents, timelines, evidence (Phase 3)
detectors/     per-detector DESIGN SPECS (not code — resources cannot include
               files from outside their own folder)
tests/         unit · integration · legitimate · simulated · regression
lab/           scenarios, fixtures, datasets
knowledge/     findings, decisions, false positives, research
scripts/       verification gates
```

Inside each resource: `logic/` and `lib/` are **pure** and unit-tested;
`adapters/`, `server/` and `sinks/` are **impure** and verified only on a live server.

## Verification

```bash
bash scripts/verify.sh   # the full CI gate
```

| Tier | Where | Status |
| --- | --- | --- |
| **A** — pure logic, schema, guards | this repo / CI | **162 tests passing**, 29 files linted, guard self-test + 13-case matrix |
| **B** — resource boot, natives, events, performance | the owner's private lab | **pending** |

Tier A cannot execute a single native. **No feature here is claimed to work on a live
server.** See [`docs/TESTING_METHODOLOGY.md`](docs/TESTING_METHODOLOGY.md).

## Getting started on the lab

Requires FXServer with a valid `sv_licenseKey`, GTA V, and `onesync on`.

```cfg
# server.cfg
set onesync on
set security_mode "LAB"          # LAB or PRODUCTION; anything unrecognised fails closed

# hardening the posture audit will otherwise report (POSTURE-002..008)
set sv_scriptHookAllowed false
setr sv_stateBagStrictMode true
set sv_entityLockdown "strict"
set sv_filterRequestControl 1
set sv_authMinTrust 2
set sv_authMaxVariance 4
set sv_endpointPrivacy true

ensure security-core
ensure security-telemetry
```

Then run `security:status` in the server console. It reports mode, uptime, whether the
server is state-aware, and the ConVar posture summary.

**OneSync `on` is required.** Without it the server-side game events and camera natives
do not exist, and `security-core` will report the platform as *blind* rather than degrade
silently.

## Documentation

| Document | What it covers |
| --- | --- |
| [`CLAUDE.md`](CLAUDE.md) | Charter for all implementation work — read first |
| [`ENVIRONMENT_AUDIT.md`](docs/ENVIRONMENT_AUDIT.md) | Measured environment, verified native/event surface |
| [`ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Components, data flow, assumptions, limitations |
| [`SECURITY_MODEL.md`](docs/SECURITY_MODEL.md) | Adversaries, claims, and explicit non-claims |
| [`TRUST_BOUNDARY.md`](docs/TRUST_BOUNDARY.md) | What is trusted, what is not, and why |
| [`TELEMETRY_SCHEMA.md`](docs/TELEMETRY_SCHEMA.md) | The record contract (schema v1) |
| [`DETECTION_MODEL.md`](docs/DETECTION_MODEL.md) | Detector contract, confidence rules, planned detectors |
| [`FALSE_POSITIVE_POLICY.md`](docs/FALSE_POSITIVE_POLICY.md) | Why FPs cost more than misses |
| [`TESTING_METHODOLOGY.md`](docs/TESTING_METHODOLOGY.md) | Two tiers, and the 8 gating experiments |
| [`PERFORMANCE_BUDGET.md`](docs/PERFORMANCE_BUDGET.md) | Costs, intents, back-out thresholds |
| [`QBCORE_INTEGRATION.md`](docs/QBCORE_INTEGRATION.md) | QBCore posture, PII policy, event audit surface |
| [`ROADMAP.md`](docs/ROADMAP.md) | Phases, status, critical path |

## Scope

**In scope:** server-side telemetry, detection logic, forensics, controlled lab
simulators that produce the *conditions* a detector must see, false-positive testing.

**Out of scope, permanently:** public cheat software or loaders, credential theft,
malware, destructive tooling, anything aimed at other servers, anything to bypass
commercial or public anti-cheat, persistence or evasion mechanisms.

See [`SECURITY.md`](SECURITY.md).

## Licence

MIT — see [`LICENSE`](LICENSE).

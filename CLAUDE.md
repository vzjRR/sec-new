# CLAUDE.md — FiveM Security Lab

**Read this before implementing anything in this repository.**

Owner: vzjRR · Platform: FiveM / FXServer · Framework: **QBCore** (`qb-core`)
Architecture: `/TSU` + `/TSG` · Status: Phase 1 complete, Phase 2 telemetry core complete

---

## 1. What this project is

A **defensive security laboratory** for a private FiveM server: a server-authoritative
observatory that records behaviour, normalizes it, reasons about it with explicit
confidence, and produces reconstructable evidence.

The objective is **not** "an anti-cheat that bans people". It is:

> a defensible, measurable, explainable FiveM security platform that identifies abnormal
> behaviour with strong evidence while minimising false positives.

## 2. Hard boundaries

**Do build:** server-side telemetry, detection logic, evidence and forensics, controlled
lab simulators that produce the *conditions* a detector must see, false-positive tests,
documentation.

**Never build:** public cheat software or loaders, credential theft, malware, destructive
tooling, anything aimed at servers other than this lab, anything designed to bypass
commercial or public anti-cheat, persistence or evasion mechanisms.

When an adversarial behaviour must be studied, build a **controlled simulator that
produces the relevant telemetry**, not a real cheat. The lifecycle is:
`understand → reproduce safely → measure → detect → validate`.

## 3. The three constraints (measured, not assumed)

Read [`docs/ENVIRONMENT_AUDIT.md`](docs/ENVIRONMENT_AUDIT.md) for the evidence.

| # | Constraint | Consequence |
| --- | --- | --- |
| **C1** | 0 of 6,416 GTA natives and 360 of 943 Cfx natives are server-callable | **There is no client-side component.** Every signal is server-observed. Do not propose one. |
| **C2** | FXServer needs a license key and cannot boot in CI; vanilla Lua 5.4 lacks CfxLua extensions | **Detection/telemetry/statistics logic must be pure Lua behind thin adapters.** |
| **C3** | Evidence bridges the two test tiers | Append-only JSONL, replayable as CI fixtures. |

### C2 in practice — the rule that governs the codebase

```
logic/ and lib/      PURE. No natives. No backtick hashes. No vector3.
                     Unit-tested in CI. This is where thinking happens.

adapters/ server/    IMPURE. Natives, events, timers. NOT unit-tested.
sinks/               Keep them THIN — they are the untested surface.
```

If you find yourself wanting a native inside `logic/`, the design is wrong: have the
adapter read it and pass a plain table.

### Module loading — do not use `require` in a resource

FiveM has **no `require`** for resource scripts. `server_scripts` files load as plain
chunks into one shared per-resource Lua state, and **the chunk's return value is
discarded** (`knowledge/research/R-004`). So every pure module ends with:

```lua
SecLab = SecLab or {}
SecLab.schema = M
return M          -- used by require() in CI; ignored by FXServer
```

Adapters read siblings off `SecLab` with an `assert`, never `require`. **`fxmanifest.lua`
order is load-bearing.** `tests/unit/test_module_loading.lua` simulates this and is the
only Tier A test covering the boot path — it exists because an earlier version used
`require`, passed CI, and would not have booted.

## 4. Build the observatory before the police

Phase order is not negotiable (charter §4, §18):

```
telemetry → forensics → detectors → correlation → lab automation → dashboard → hardening
```

**Detection and enforcement are separate systems.** A detector never bans, kicks,
cancels an event, or mutates game state. `scripts/check_no_enforcement.lua` is a build
gate that fails on `CancelEvent`, `DropPlayer`, `Kick`, `TriggerClientEvent`,
`SetEntity*`, `AddPermission` and friends inside `resources/` and `detectors/`.

Adding enforcement is a **charter change**: validate the incident model first, record a
decision in `knowledge/decisions/`, then amend the guard. Never just edit the guard.

## 5. Evidence standard

Tag every claim in docs and commit messages:

| Tag | Meaning |
| --- | --- |
| **FACT** | Official Cfx.re/QBCore documentation, or machine-readable Cfx.re data |
| **OBSERVATION** | Measured here; command and output recorded |
| **HYPOTHESIS** | Plausible, untested. **May not become a detection rule.** |

Rules that follow from this:

- **Do not invent natives, events, or framework APIs.** If uncertain, check
  `docs.fivem.net`, the natives JSON, or `qbcore.org/docs` — and record the uncertainty
  if it stays unresolved. There is no documented *server-side* QBCore player-loaded
  event; we poll instead of guessing an event name. Keep that discipline.
- **Never turn a hypothesis into a threshold.** `EXP-001` (camera rotation
  characteristics) blocks all aim detection. `EXP-002` (weaponDamageEvent fields) blocks
  derived combat measurements. See `docs/TESTING_METHODOLOGY.md`.
- **Never claim a feature works without a test.** State which tier verified it.

## 6. Trust discipline

Every telemetry record carries a `trust` field — `observed`, `claimed`, `derived`,
`framework` (`docs/TELEMETRY_SCHEMA.md` §6). This is not decoration:

- A `weaponDamageEvent` payload is a **client claim**. Its fields are attacker-chosen.
- The *fact* that the server observed that claim, and *when*, is trustworthy.
- So detectors reason about **sequences, rates and geometric consistency**, never about
  whether one claimed field "looks wrong".
- A detection resting only on `claimed` measurements **may not exceed confidence 0.5**.
  Raising it requires an `observed` corroboration.

Never fold a claim and an observation into the same record — emit both and join them by
`correlation_id`.

## 7. Coding conventions

**Lua (primary).**
- CfxLua is modified Lua 5.4. `logic/`/`lib/` must parse under vanilla `lua5.4`.
- `local` everything; return a module table. No globals from pure modules.
- Inject dependencies (clock, writer, config) — never reach for ambient state. This is
  what makes tests deterministic.
- `snake_case` for variables and functions, `SCREAMING_CASE` for constants,
  `PascalCase` for metatable classes.
- Wrap every adapter callback in `pcall`. **A malformed client payload must never crash
  the adapter** — that would be a denial of service against our own observability.
- Validate and drop, never coerce. A string where a number belongs is dropped, not
  `tonumber`'d: silently coercing attacker input manufactures measurements.

**Measurement units are mandatory.** Every measurement key ends in a unit suffix
(`_ms`, `_m`, `_mps`, `_deg`, `_pct`, `_n`, …). An unlabelled number is a bug and the
schema validator rejects it. Where a unit is genuinely unknown (`damageTime`), use `_n`
to record the uncertainty in the data itself.

**Comments explain *why*.** The code says what. If a threshold, interval or trade-off
has a justification, write it down — future-you will otherwise "optimise" it away.

## 8. FiveM conventions

- `fxmanifest.lua`, `fx_version 'cerulean'`, `game 'gta5'`.
- Resources live in `resources/[vzjrr-security]/`. `security-core` starts first.
- Cross-resource communication via `exports`, never globals.
- **OneSync `on` is required.** Without it the server game events and camera natives do
  not exist. `security-core` detects this and reports the platform as *blind* — do not
  let it degrade silently.
- Under OneSync Infinity all player iteration is server-side (`GetPlayers`), and
  entities beyond the 424-unit focus zone are culled.
- Prefer event-driven signals. Where polling is unavoidable, use the lowest useful
  frequency and justify it in `lib/config.lua`. Peer statistics only refresh every 10
  seconds — polling faster is waste.

## 9. QBCore conventions

See [`docs/QBCORE_INTEGRATION.md`](docs/QBCORE_INTEGRATION.md).

- Use the documented export `exports['qb-core']:GetPlayer(source)`, wrapped in `pcall`.
  Do **not** import the whole core object.
- QBCore is an **optional** dependency. If absent, disable enrichment, say so in health
  output, and keep running — core telemetry never needed it.
- `player_key = "QB:" .. citizenid`. Stable, opaque, non-identifying.
- **Never collect `charinfo`** (`firstname`, `lastname`, `birthdate`, `phone`,
  `account`) or platform identifiers. The schema validator fails CI if they appear.
- Never call QBCore mutators: `Kick`, `AddPermission`, `SetPlayerBucket`, `SpawnVehicle`.
- `HasPermission` is a **false-positive control** — admin teleports are a legitimate
  cause of impossible movement. Use it from day one.

## 10. Testing requirements

```
bash scripts/verify.sh     # the whole Tier A gate: lint + guard + unit tests
bash scripts/lint.sh       # luac5.4 -p syntax gate over every .lua
bash scripts/test.sh       # pure-Lua unit tests
```

| Tier | Where | Can verify | Cannot verify |
| --- | --- | --- | --- |
| **A** | this container / CI | pure logic, schema, fixtures, replay | anything needing FXServer |
| **B** | owner's private lab | resource boot, natives, events, performance, scenarios | — |

- Every detector needs unit tests, a false-positive test, a lab scenario, and a
  performance measurement before it is called done.
- Tests assert on **error messages**, not just booleans — otherwise they pass for the
  wrong reason once an unrelated field breaks.
- **Test the guards.** A build gate that cannot fail is worthless; `check_no_enforcement`
  self-tests before it runs, because a first version silently passed everything.
- Fixtures are **never rewritten to match new code** — that destroys the regression
  signal. A schema change keeps the old fixtures and bumps `schema_version`.

## 11. Detector requirements

A detector is a pure function: `detect(state, record, config) -> DetectionResult | nil`.

Every detector needs, before it ships:
design spec in `detectors/<domain>/` · implementation in `security-detectors/logic/` ·
unit tests · a false-positive test · a lab scenario ID · a performance measurement ·
documentation.

A `DetectionResult` carries `detector_id`, `detector_version`, `player_key`, `timestamp`,
`signal`, `measurements`, `confidence`, `severity`, `evidence_refs`, `explanation`,
`context`. The `explanation` must let a human answer *why*, without reading the code.

**Do not use a single metric as a decision.** "accuracy > X = cheating" is exactly the
reasoning this project exists to replace. Think distributions, variance, repetition,
context, history, population baselines, and multiple independent signals.

**Account for legitimate causes.** For movement: admin actions, teleport scripts,
interiors, respawn, lag, packet loss, network correction, vehicle mechanics,
server-side movement systems. A detector that ignores these is a false-positive
generator.

## 12. Performance requirements

Security must not damage the server (charter §15). Every feature documents expected CPU,
memory, network and storage cost in `docs/PERFORMANCE_BUDGET.md`.

- Prefer events over polling; prefer lower frequency over higher.
- Bounded memory everywhere. The telemetry ring buffer is capacity-limited and
  **counts drops**, because a silent gap in evidence is worse than no evidence.
- Keep query cost offline. The hot path appends; analysis happens out of process.

## 13. Documentation requirements

- Update `docs/` in the same change as the code. A doc that lags the code is worse than
  no doc.
- Record findings in `knowledge/`: `patterns/`, `incidents/`, `false-positives/`,
  `research/`, `decisions/`. **Never silently replace knowledge** — supersede it with a
  dated entry that says what changed and why.
- Log every documentation discrepancy you find. The `sv_lan` license-bypass claim is
  documented but does not work (audit §6.3); that finding has already saved time twice.
- `CHANGELOG.md` gets an entry per meaningful change.

## 14. Workflow for every substantial task

1. **Understand** — re-read the relevant `docs/`.
2. **Inspect** — look at what exists. Do not assume framework, DB, or resource names.
3. **Plan** — a short written plan before touching multiple files.
4. **Implement** — small, verifiable changes. Do not rewrite working code for style.
5. **Test** — `bash scripts/verify.sh`. Add tests for new logic.
6. **Review** — read your own diff adversarially.
7. **Document** — `docs/`, `knowledge/`, `CHANGELOG.md`.
8. **Report** — using the §27 format: Completed / Files Changed / Tests / Results /
   Problems / Security Considerations / Performance / Next Task.

State honestly what was *not* verified. Tier A passing is not Tier B passing.

## 15. Current state

**Done (Tier A verified):** repository structure; environment audit; architecture;
telemetry schema + validator; clock, envelope, normalizers, bounded buffer;
LAB/PRODUCTION mode; typed config; structured logger; ConVar posture auditor;
`security-core` and `security-telemetry` resources with adapters; the no-enforcement
guard; Phase 3 forensics core (detection type with enforced confidence caps, incident
lifecycle, gap-aware timeline); **249 unit tests**.

**Not verified:** anything requiring FXServer. **Nothing in this repository has yet run
inside a FiveM server.** That is a consequence of C2, not an oversight.

**Blocked on the lab (Tier B):** `EXP-001` … `EXP-008` in
`docs/TESTING_METHODOLOGY.md`. `EXP-001` and `EXP-002` block all aim and combat
detection work.

**Next:** the remaining Phase 3 items (evidence store, investigation export), then wire
the **ConVar posture audit** as a formal detector — it has zero false-positive risk
against players and hardens the server even when nobody is cheating.

# TESTING METHODOLOGY

**Grounded in:** `ENVIRONMENT_AUDIT.md` §6.3 (no FXServer in CI) and §9.1 (vanilla Lua
vs CfxLua).

---

## 1. Two tiers, and why

| Tier | Where | Verifies | Cannot verify |
| --- | --- | --- | --- |
| **A** | build container / CI | pure logic, schema, fixtures, replay, guards | anything needing FXServer |
| **B** | owner's private lab | resource boot, natives, events, performance, scenarios | — |

Tier A exists because Tier B cannot be automated: FXServer needs a license key and a GTA
V client. Tier B exists because Tier A cannot execute a single native.

**The bridge is the JSONL telemetry file.** Tier B captures real telemetry; curated
captures become committed fixtures; Tier A replays them forever. This is what makes the
knowledge loop (charter §22) mechanical rather than aspirational — a detector's
behaviour on real recorded data can be re-verified without a game client.

**No feature is reported as working on the strength of Tier A alone.** Every claim states
its tier.

## 2. Running Tier A

```bash
bash scripts/verify.sh   # lint + no-enforcement guard + unit tests
bash scripts/lint.sh     # luac5.4 -p over every .lua
bash scripts/test.sh     # pure-Lua unit tests
```

Current: **162 unit tests, 29 Lua files linted, guard self-test + 13-case matrix.**

## 3. The pyramid

```
unit  ──▶ detector ──▶ telemetry ──▶ integration ──▶ scenario ──▶ full-server ──▶ regression
└──────────── Tier A ─────────────┘  └────────────── Tier B ──────────────┘   └── Tier A ──┘
```

Regression lands back in Tier A because that is the only tier that can run unattended.

## 4. Testing principles learned here

These are not generic advice; each came from a bug in this repository.

**Assert on error messages, not just booleans.** `H.rejects(ok, errs, needle)` requires
the rejection to mention the expected reason. Without it a validation test keeps passing
after it starts failing for an unrelated reason.

**Simulate the runtime's loading contract.** `tests/unit/test_module_loading.lua` loads
each resource the way FXServer does — `loadfile` into a shared environment, chunk return
value discarded — because FiveM has no `require` for resource scripts (R-004). An
earlier version of this codebase used `require` in its adapters: CI was green and the
resource would not have booted. Tier A can pass while the resource is unloadable, and
the answer is to model the loading contract, not to trust Tier A less.

**Test the guards.** `scripts/check_no_enforcement.lua` self-tests before it runs,
because the first grep-based version **silently passed everything** — an unescaped `(`
made the regex invalid and the error was swallowed. A later version missed the
`QBCore.Functions.Kick(...)` dot form. A build gate that cannot fail is worse than no
gate: it produces false confidence.

**Test hostile input explicitly.** Normalizers receive attacker-controlled payloads.
`test_normalize.lua` feeds them nil, empty tables, strings where numbers belong, NaN,
infinity, tables where scalars belong, and a non-array `hitGlobalIds`. An adapter crash
is a denial of service against our own observability.

**Test that defaults are the *documented* defaults.** `test_posture.lua` asserts that an
empty config trips seven checks *and* that `sv_scriptHookAllowed` unset is **not**
flagged, because it genuinely defaults to `false`. Getting that backwards would fire on
every correctly configured server.

**Fixtures are never rewritten to match new code.** That destroys the regression signal.
A schema change keeps old fixtures and bumps `schema_version`.

## 5. Scenario format (Tier B)

```
ID:                     AIM-001
Objective:              what behaviour/condition is being produced
Environment:            LAB (always — simulators are refused in PRODUCTION)
Setup:                  exact steps, server config, participants
Expected telemetry:     categories, events, measurement ranges
Expected detector:      detector_id + expected confidence band, or "none yet"
Expected result:        pass criteria
Legitimate comparison:  the benign scenario that must NOT fire
False-positive risks:   what could make this fire wrongly
Cleanup:                how to restore state
Regression:             the fixture this run contributes
```

The **legitimate comparison** is mandatory. A scenario that only proves a detector fires
on the bad case says nothing about its false-positive rate.

## 6. Legitimate scenarios that must not fire

Per charter §QA. Each needs a fixture:

skilled players · high ping · packet loss · FPS drops · controller input · mouse input ·
differing sensitivities · vehicle combat · NPC combat · legitimate teleport scripts ·
admin actions · interiors · cutscenes · resource restarts · reconnects · server restarts ·
routing-bucket changes · respawn.

## 7. Prerequisite experiments (Tier B)

**These gate detector work.** Charter §21: a hypothesis may not become a rule.

| ID | Question | Blocks | Method |
| --- | --- | --- | --- |
| **EXP-001** | `GET_PLAYER_CAMERA_ROTATION`: update rate, precision, smoothing; behaviour in first/third person, in vehicles, in cutscenes, while dead | **all aim detection** | Poll at several rates for a known camera motion; compare against client-side ground truth recorded separately in LAB |
| **EXP-002** | `weaponDamageEvent`: `damageTime` clock base and unit; `hitGlobalId` vs `hitGlobalIds[]`; behaviour on miss vs hit; the undocumented fields `f104`, `f112`, `f112_1`, `f120`, `f133` | derived combat measurements | Fire known shots (hit, miss, multi-hit, vehicle, silenced) and record raw payloads in LAB |
| **EXP-003** | `GET_PLAYER_PEER_STATISTICS` refresh behaviour under induced latency and loss | network-conditioned thresholds | `tc`/clumsy-induced impairment, compare reported vs induced |
| **EXP-004** | Installed `qb-core` version; is `exports['qb-core']:GetPlayer` available? | framework enrichment | Read `fxmanifest.lua`; call the export |
| **EXP-005** | Do the documented weaknesses in `QBCore:Server:SetMetaData` exist in the live source? | event-audit contracts | Read the installed `qb-core` source |
| **EXP-006** | Which resources are installed, and which register client-triggerable events that mutate server state? | event contract inventory, economy scope | Enumerate `RegisterNetEvent` handlers across installed resources |
| **EXP-007** | Is `metadata.isdead` reliably set server-side at the moment of death? | `combat.dead_shooter` | Controlled deaths; compare timing against `GET_ENTITY_HEALTH` |
| **EXP-008** | Is `io.open` append available to server-side Lua on the target build? Where is the resource CWD? | the JSONL sink | Attempt a write from `security-telemetry`; inspect the path |

| **EXP-009** | Is `require`/`package` available at all to server-side resource scripts? | confirms R-004 and the dual-export design | `print(type(require), type(package))` from a server script |

`EXP-008` is worth calling out: the JSONL sink is written but **unverified**. If `io` is
restricted on the target build, the sink must change to KVP batching or an HTTP shipper.
The sink interface exists so that is a swap, not a rewrite.

## 8. Reporting

Per charter §27, every substantial task reports: Completed · Files Changed · Tests ·
Results · Problems · Security Considerations · Performance · Next Task — and states which
tier verified what.

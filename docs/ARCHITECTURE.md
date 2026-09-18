# ARCHITECTURE — FiveM Security Lab

**Task:** TASK 002 — Security Architecture
**Date:** 2026-09-18
**Status:** Proposed. Phase 1 + Phase 2 telemetry core implemented against it; live verification pending (Tier B).
**Depends on:** [`ENVIRONMENT_AUDIT.md`](ENVIRONMENT_AUDIT.md) — every constraint below is traced to a measured finding there.
**Framework target:** **QBCore** (`qb-core`), confirmed by the owner. See [`QBCORE_INTEGRATION.md`](QBCORE_INTEGRATION.md).

---

## 1. What this system is, and what it is not

**It is** an observatory: a server-authoritative pipeline that records what happened,
normalizes it, reasons about it with explicit confidence, and produces reconstructable
evidence.

**It is not** an enforcement system. There is no ban path, no kick path, and no
`CancelEvent()` call anywhere in the telemetry or detection layers. Per the project
charter (`§10`, `§12`), detection and enforcement are separate systems, and enforcement
is out of scope until the incident model has been validated. The audit notes
(§7.3) that `weaponDamageEvent`, `explosionEvent`, `entityCreating` and
`playerConnecting` are all cancellable, which makes premature enforcement a single line
of code away. That line is deliberately absent, and `scripts/check-no-enforcement.sh`
fails the build if it appears.

---

## 2. The three constraints that shape everything

All three are measured, not assumed. See `ENVIRONMENT_AUDIT.md` for evidence.

### C1 — Server-side only, and the surface is finite

0 of 6,416 GTA natives are server-callable; 360 of 943 Cfx natives are. Client-side
code cannot be trusted (it runs on the adversary's machine), so **every signal this
system acts on comes from the server**. The available surface is enumerated in audit
§7.2–§7.6 and is the design space — not a starting point to be extended with client
reports.

**Consequence:** there is no client-side component in this architecture. Not "a small
one", not "a signed one". None. A client-side agent would be the first thing an attacker
neutralises, and its absence is what makes every signal here defensible.

### C2 — No FXServer in CI, so logic must be pure

FXServer requires a license key and will not boot in the build environment (audit §6.3).
Vanilla Lua 5.4 can execute FiveM Lua only where CfxLua extensions are avoided
(audit §9.1). Therefore:

> **Detection, telemetry normalization, statistics and correlation are pure Lua
> functions with no native calls, no backtick hash literals and no `vector3`.
> All native and event access lives in thin adapters.**

This is the load-bearing rule of the codebase. It is what makes automated regression
testing possible at all, and it happens to coincide exactly with the detector contract
the charter already required (`§10`): a detector is a pure function from telemetry to a
detection result.

### C3 — Evidence must survive the container

Telemetry is the bridge between the two test tiers (audit §9.3). Real captures from the
owner's lab become committed fixtures; CI replays them forever. This is why the storage
format is an append-only, self-describing, plain-text record rather than an opaque
database — the same artifact serves forensics *and* regression testing.

---

## 3. Component map

```
                          ┌─────────────────────────────────────────┐
   FXServer (OneSync on)  │  RUNTIME — resources/[vzjrr-security]/  │
                          └─────────────────────────────────────────┘

  game events ─────┐
  (weaponDamage,   │
   explosion,      │      ┌──────────────────┐
   entityCreating, ├─────▶│  ADAPTERS        │  impure: natives, events, timers
   playerJoining,  │      │  (security-*/    │  NOT unit-tested in CI
   playerDropped,  │      │   adapters/)     │  kept deliberately thin
   scope, bucket)  │      └────────┬─────────┘
                   │               │ plain Lua tables only
  polled state ────┘               ▼
  (coords, velocity,      ┌──────────────────┐
   camera rotation,       │  TELEMETRY CORE  │  PURE Lua
   ping, peer stats,      │  schema/normalize│  ◀── unit-tested in CI
   health, armour,        │  /envelope/clock │
   weapon, vehicle)       └────────┬─────────┘
                                   │ TelemetryRecord (v1)
                   ┌───────────────┼───────────────┐
                   ▼               ▼               ▼
          ┌────────────┐  ┌────────────────┐  ┌──────────┐
          │  SINKS     │  │  PLAYER STATE  │  │ DETECTORS│  PURE Lua
          │ jsonl/     │  │  MODEL         │  │ (pure fn)│  ◀── unit-tested
          │ stdout/    │  │  (pure, rolling│  │          │
          │ memory     │  │   windows)     │  └────┬─────┘
          └─────┬──────┘  └────────────────┘       │ DetectionResult
                │                                   ▼
                │                          ┌────────────────┐
                │                          │  CORRELATION   │  PURE Lua
                │                          │  (multi-signal)│  ◀── unit-tested
                │                          └───────┬────────┘
                │                                  │ RiskAssessment
                ▼                                  ▼
        ┌───────────────┐                  ┌────────────────┐
        │ EVIDENCE      │◀─────────────────│  INCIDENTS     │  PURE Lua
        │ (JSONL files) │   correlation_id │  (lifecycle)   │  ◀── unit-tested
        └───────┬───────┘                  └────────────────┘
                │
                ▼  offline, out-of-process
        ┌───────────────────────────────────────────────┐
        │ ANALYSIS (node:sqlite)  ·  CI REPLAY (lua5.4) │
        │ dashboard  ·  baselines  ·  regression suite  │
        └───────────────────────────────────────────────┘
```

### 3.1 Resources

| Resource | Role | Purity |
| --- | --- | --- |
| `security-core` | Boot, config, LAB/PRODUCTION mode, structured logging, health/status, ConVar posture audit, module registry | Adapters impure; `lib/` pure |
| `security-telemetry` | Event adapters, state pollers, normalization into `TelemetryRecord`, sinks | Adapters impure; `logic/` pure |
| `security-forensics` | Evidence store, timelines, incident lifecycle, investigation exports | Mostly pure |
| `security-detectors` | Detector registry + per-domain pure detector logic | `logic/` pure; registry thin |

Load order matters: `security-core` must start first (it owns config and logging).

### 3.2 Module loading — a FiveM constraint worth knowing

**FiveM has no documented `require` for resource scripts.** Every file listed in
`server_scripts` is loaded as a plain chunk into one shared per-resource Lua state, and
**the chunk's return value is discarded**. Vanilla Lua 5.4 — the CI tier — is the
opposite: it uses the return value and has no shared namespace.

So every pure module ends with a **dual export**:

```lua
SecLab = SecLab or {}
SecLab.schema = M
return M          -- used by require() in CI; ignored by FXServer
```

Adapters read siblings off `SecLab` with an `assert`, never `require`. Each resource has
its own Lua state, so `SecLab` does not leak between resources.

Two consequences:

1. **`fxmanifest.lua` ordering is load-bearing.** A module must be listed before anything
   that reads it. The asserts in each adapter fail loudly if that order breaks.
2. **`tests/unit/test_module_loading.lua` simulates this loading model** — `loadfile`
   into a shared environment, return value thrown away — and checks that every module is
   still reachable, that it is functional and not merely present, and that the manifest
   lists it in the right order.

That test exists because an earlier version of this codebase used `require 'lib.mode'`
in its adapters. It passed CI and **would have failed at boot on a real server** — the
precise class of defect Tier A is otherwise blind to. It also immediately caught a
missing `fxmanifest.lua` for `security-forensics`.

### 3.3 Repository layout, and why `detectors/` is not code

FiveM resources cannot include files from outside their own folder, so **implementation
lives inside the resources**. The top-level `detectors/<domain>/` directories hold each
detector's **design specification** — objective, telemetry consumed, signal definition,
thresholds and their justification, false-positive analysis, performance budget, and the
scenario IDs that verify it. Per the charter (`§18` Phase 4), a detector needs a design
before an implementation; this split keeps the design reviewable independently of the code.

```
docs/            architecture, models, policies  (this directory)
agents/          the 18 role charters (§3 of the master prompt)
config/          shipped default configuration
resources/[vzjrr-security]/
                 the FiveM resources — all runtime code
detectors/       per-detector DESIGN SPECS (not code)
tests/           unit · integration · legitimate · simulated · regression
lab/             scenarios, fixtures, datasets, local server helpers
knowledge/       cumulative findings, decisions, FP catalogue, research
scripts/         syntax gate, test runner, guard checks
dashboard/       SOC interface (Phase 7)
```

---

## 4. Data flow

### 4.1 Ingestion

Two paths, deliberately different in cost:

**Event-driven (preferred).** A FiveM event fires; the adapter converts it to a
`TelemetryRecord` and hands it to the core. Cost is proportional to actual activity.
Used for: `weaponDamageEvent`, `explosionEvent`, `startProjectileEvent`,
`entityCreating`/`entityCreated`/`entityRemoved`, `playerJoining`, `playerDropped`,
`playerEnteredScope`/`playerLeftScope`, `onPlayerBucketChange`.

**Polled (minimised).** Some state has no event: position, velocity, camera rotation,
health, armour, weapon, ping, peer statistics. These are sampled on a timer. Per the
charter (`§15`), polling frequency must be the lowest that still supports the signal, and
every poller declares its interval in config. Peer statistics refresh only once per 10
seconds server-side (audit §7.5), so polling them faster is pure waste — the config
default reflects that.

### 4.2 Normalization

Every record becomes the same shape (see [`TELEMETRY_SCHEMA.md`](TELEMETRY_SCHEMA.md)).
Adapters do not invent their own log formats. This is the charter's
`TELEMETRY-ENGINEER` requirement and it is enforced by a schema validator that runs in
CI against every fixture.

### 4.3 Detection

A detector is a pure function:

```
detect(state, record, config) -> DetectionResult | nil
```

It receives the rolling player state and the new record, and returns a result or
nothing. It cannot call natives, read files, or trigger events. It cannot ban.
See [`DETECTION_MODEL.md`](DETECTION_MODEL.md).

### 4.4 Correlation and incidents

Independent signals combine into a `RiskAssessment` that must be able to answer *why*
(charter `§11`). Incidents follow the `OBSERVING → INVESTIGATING → CONFIRMED / DISMISSED
→ RESOLVED` lifecycle and carry their evidence references, detector versions and
timeline. High confidence is never equated with enforcement (charter `§12`).

---

## 5. Trust boundaries

Full treatment in [`TRUST_BOUNDARY.md`](TRUST_BOUNDARY.md). The summary:

| Boundary | Trust | Notes |
| --- | --- | --- |
| Game client → server | **Zero** | Runs on the adversary's machine. |
| Client-triggered net events | **Zero** | Every `RegisterNetEvent` handler is an attack surface. `source` is trustworthy; all arguments are not. |
| Player state bag writes | **Zero by default** | `sv_stateBagStrictMode` defaults to `false`, so clients *can* write their own player state (audit §7.7). |
| Client-created entities | **Zero by default** | `sv_entityLockdown` defaults to `inactive` (audit §7.7). |
| Routed game events (`weaponDamageEvent`, …) | **Low — attacker-influenced** | The *fact* of routing and the `sender` are server-observed; the payload originates client-side. Treat fields as claims. |
| Server natives (`GET_ENTITY_COORDS`, `GET_PLAYER_CAMERA_ROTATION`, …) | **High** | Server-computed from sync state. Still subject to lag and interpolation. |
| QBCore `PlayerData` | **Server-side, integrity-dependent** | Authoritative as *the server's view*; only as correct as the resources that write it. |
| Our own evidence store | **High** | Append-only, local. |

**The key subtlety, and the one most anti-cheats get wrong:** a `weaponDamageEvent`
payload is *not* trustworthy data, but the *pattern* of payloads is a trustworthy
observation. An attacker controls what they claim; they do not control the fact that the
server observed them claiming it, nor when. Detectors must therefore reason about
sequences, rates and geometric consistency — never about whether a single claimed field
"looks wrong".

---

## 6. LAB / PRODUCTION separation

Per charter `§8`. Mode is resolved once at boot from the `security_mode` ConVar and is
immutable for the process lifetime.

| Capability | LAB | PRODUCTION |
| --- | --- | --- |
| Verbose / debug telemetry | yes | no |
| Synthetic event injection | yes | **refused** |
| Scenario simulators | yes | **refused** |
| Experimental detectors | yes | no |
| Developer commands | yes | no |
| Raw payload capture (unknown event fields) | yes | no |
| Core telemetry + detection | yes | yes |

Two independent guards, because one is not enough for a footgun this size
(charter `§8`: "Never accidentally ship a simulator as part of production protection"):

1. **Runtime** — simulator entry points check the mode and refuse, loudly, in PRODUCTION.
2. **Packaging** — simulators live in a separate resource (`lab/`) that is not part of
   the protection resource set at all. A PRODUCTION deployment does not contain the code.

Unknown-field capture is LAB-only on purpose: audit §7.3 notes several undocumented
`weaponDamageEvent` fields, and characterising them requires recording raw payloads —
which is a privacy and volume risk that does not belong in production.

---

## 7. Storage

Per audit §8, unchanged by the QBCore decision:

| Tier | Mechanism | Holds |
| --- | --- | --- |
| Hot config / counters | FXServer KVP | mode, detector versions, rolling counters, baselines |
| Evidence | Append-only JSONL on disk | telemetry, timelines, incidents |
| Analysis | `node:sqlite` reading the JSONL, offline | queries, baselines, dashboard, regression |

QBCore servers normally run MySQL via `oxmysql`. This project deliberately does **not**
write to the QBCore database:

- **Separation of concerns.** Security evidence should not share a failure domain with
  the gameplay database. If the game DB is down, the observatory must keep recording —
  that is precisely when incidents are most likely.
- **Integrity.** Append-only files are a better forensic record than mutable rows.
- **No new dependency.** The audit found no database server available in CI (§5), so a
  DB-coupled design would be untestable.

A `storage` interface exists from Phase 2 so adding an `oxmysql` sink later is a
configuration change, not a rewrite.

---

## 8. QBCore integration posture

Detail in [`QBCORE_INTEGRATION.md`](QBCORE_INTEGRATION.md). The principles:

1. **Loose coupling via exports.** `exports['qb-core']:GetPlayer(source)` — documented
   for `qb-core` ≥ 1.3.0 — not `GetCoreObject()` wholesale. Less memory, smaller blast
   radius, and it degrades gracefully.
2. **Optional dependency.** If `qb-core` is absent or older, the platform runs with
   framework enrichment disabled and says so in its health output. It never hard-fails,
   because the core FiveM telemetry does not need QBCore.
3. **`citizenid` is the durable player key.** Stable across sessions, opaque, and not
   personally identifying — exactly what telemetry needs.
4. **`charinfo` is PII and is never collected.** `firstname`, `lastname`, `birthdate`,
   `phone`, `account` have no detection value and real privacy cost.
5. **QBCore is a *subject* of security review, not just a source.** Its documented
   client-triggerable events are an audit target (see `QBCORE_INTEGRATION.md` §4).

---

## 9. Security assumptions

Stated explicitly so they can be challenged:

1. **The server host is not compromised.** If it is, nothing here helps.
2. **OneSync is `on`.** Without it, the routed game events and camera natives do not
   exist (audit §7.8). `security-core` checks this at boot and degrades loudly.
3. **Other resources are not actively hostile.** A malicious resource on the same server
   shares our process and can lie to us or read our data. Out of scope; noted.
4. **Server-native values are the server's honest view of sync state** — not ground
   truth about the client's screen. Lag, interpolation and culling all distort them.
5. **Attackers can read this repository.** Nothing here relies on the detector logic
   being secret. Thresholds are configurable and expected to be tuned per server;
   security comes from the signals being server-observed, not from obscurity.
6. **A determined attacker who limits themselves to plausible behaviour will not be
   caught by behavioural detection.** That is inherent, not a defect. The goal
   (charter `§28`) is defensible, measurable, explainable detection with few false
   positives — not perfect coverage.

---

## 10. Limitations

Honest and specific, per charter `§20`/`§21`:

1. **No client-side integrity checking.** Injected DLLs, modified game files and cheat
   loaders are invisible to this system by design (C1). It observes *behaviour and its
   consequences*, not client integrity.
2. **Aim telemetry is real but uncharacterised.** `GET_PLAYER_CAMERA_ROTATION` is
   server-side (audit §7.2), but its update rate, precision and behaviour in vehicles /
   first person / cutscenes are unmeasured. **EXP-001 blocks all aim detection.**
3. **`weaponDamageEvent` has undocumented fields** and an unknown `damageTime` clock
   base (audit §7.3). **EXP-002** must characterise them before any derived measurement
   is trusted.
4. **Peer statistics lag by 10 seconds** (audit §7.5), so network context is
   window-level, not per-shot.
5. **OneSync Infinity culls at 424 units** (audit §7.8), so server knowledge of distant
   entities is limited and enumeration cost scales with world population.
6. **Polling cannot see between samples.** A sub-interval teleport that returns may be
   invisible. Event-driven signals do not have this gap; movement detection does.
7. **No population baseline exists yet.** Until one does, statistical detectors have
   nothing to compare against, which is why Phase 4 starts with config audit and rate
   anomalies rather than behavioural scoring.
8. **A detector's absence of alerts is not evidence of a clean server.**

---

## 11. Verification status

Per charter `§27`, nothing is claimed to work without a test.

| Layer | Tier A (CI, this container) | Tier B (owner's lab) |
| --- | --- | --- |
| Pure telemetry core | **verified** — unit tests pass | pending |
| Schema validator | **verified** | pending |
| Pure detector scaffolding | **verified** | pending |
| Config / mode resolution | **verified** (pure parts) | pending |
| Resource boot | not possible (C2) | **pending — required** |
| Adapters, natives, events | not possible (C2) | **pending — required** |
| Performance | not possible | **pending — required** |

**Nothing in this repository has yet run inside FXServer.** That is the honest state,
and it is a consequence of C2, not an oversight.

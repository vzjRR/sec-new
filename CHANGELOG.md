# Changelog

All notable changes to the FiveM Security Lab.

Tags follow `CLAUDE.md` §5: **FACT** (documented), **OBSERVATION** (measured here),
**HYPOTHESIS** (untested).

## [Unreleased]

### Phase 1 — Foundation, and Phase 2 telemetry core

#### Added — documentation
- `docs/SECURITY_MODEL.md` — adversary model A1–A8, explicit claims and non-claims,
  defence-in-depth ordering, kill chain and where we intervene.
- `docs/TRUST_BOUNDARY.md` — per-boundary trust rules and the confidence caps that
  follow from them.
- `docs/DETECTION_MODEL.md` — detector contract, `DetectionResult`, confidence bands
  and hard caps, incident lifecycle, the 7 planned detectors in shipping order.
- `docs/TESTING_METHODOLOGY.md` — two-tier topology and the 8 gating experiments
  (`EXP-001` … `EXP-008`).
- `docs/FALSE_POSITIVE_POLICY.md` — why a false positive costs more than a miss.
- `docs/PERFORMANCE_BUDGET.md` — declared intents (not measurements), poll-interval
  justifications, storage problem, back-out thresholds.
- `docs/ROADMAP.md` — phase status and the critical path.
- `agents/` — 18 role charters plus an index, each naming its verified surface,
  blockers, definition of done and anti-patterns.
- `knowledge/` — 6 seed entries: 3 research findings and 3 architecture decisions.
- `detectors/README.md` and `detectors/server/POSTURE-AUDIT.md` — the first detector
  design spec.
- `README.md`, `SECURITY.md`, `LICENSE`, `.gitignore`.
- `config/README.md` — generated from the config schema by
  `scripts/gen-config-docs.sh`, so the reference cannot drift from the code.

- `docs/ENVIRONMENT_AUDIT.md` — TASK 001 environment discovery.
- `docs/ARCHITECTURE.md` — TASK 002 security architecture.
- `docs/TELEMETRY_SCHEMA.md` — versioned `TelemetryRecord` contract (schema version 1).
- `docs/QBCORE_INTEGRATION.md` — QBCore posture, PII policy, event-audit surface.
- `CLAUDE.md` — project charter for all future implementation work.

#### Added — pure logic (unit-tested, Tier A)
- `security-telemetry/logic/schema.lua` — record validation: envelope completeness,
  category/trust enums, numbers-only measurements, mandatory unit suffixes, PII sweep.
- `security-telemetry/logic/clock.lua` — injected time sources; clamps a regressing
  monotonic clock and returns `nil` rather than `0` for an untrustworthy interval.
- `security-telemetry/logic/envelope.lua` — single point of record construction.
- `security-telemetry/logic/normalize.lua` — pure normalizers for `weaponDamageEvent`,
  `explosionEvent`, entity lifecycle, player lifecycle, network, movement and aim samples.
- `security-telemetry/logic/buffer.lua` — bounded ring buffer that counts drops.
- `security-core/lib/mode.lua` — LAB/PRODUCTION, failing closed to PRODUCTION.
- `security-core/lib/config.lua` — typed, bounded, self-documenting config schema.
- `security-core/lib/logger.lua` — structured logging with an injected writer.
- `security-core/lib/posture.lua` — ConVar posture auditor (8 checks).

#### Added — adapters (Tier B verification pending)
- `security-core` resource: boot, mode resolution, config, logging, health export,
  posture audit on boot and on a timer, `security:status` command.
- `security-telemetry` resource: event adapters, pollers, identity resolution,
  memory/jsonl/stdout sinks.

#### Added — Phase 3 forensics core (pure, unit-tested)
- `security-forensics/logic/detection.lua` — the `DetectionResult` type with the
  confidence policy **enforced by construction**: claimed-only detections are capped
  at 0.5, anything built on an uncharacterised native (EXP-001 camera rotation,
  EXP-002 `damageTime`) is capped at 0.3, the original request is preserved for audit,
  and each cap names its reason. An undeclared trust basis fails closed. An explanation
  shorter than 30 characters is rejected, because "score 0.87" is not evidence.
- `security-forensics/logic/incident.lua` — incident model and lifecycle. `CONFIRMED`
  and `DISMISSED` both require a stated basis; `CONFIRMED → DISMISSED` is deliberately
  not an allowed transition, so withdrawing a confirmation leaves a trace via
  `RESOLVED`. Confidence aggregation is `max`, not a sum, because combining
  confidences requires arguing independence (Phase 5).
- `security-forensics/logic/timeline.lua` — gap-aware timeline assembly. A missing
  `seq` is detectable, so lost evidence becomes a first-class timeline entry rather
  than a silent hole an investigator would read as continuity. Filtered timelines
  suppress false gap reports. `trust_summary()` states how much of a story the
  attacker controlled.

#### Added — Phase 3 completion (pure, unit-tested)
- `security-telemetry/logic/jsonl.lua` — a deterministic JSON encoder and strict
  decoder, purpose-built for telemetry records. **Keys are sorted**, because
  `json.encode` gives no order guarantee and fixtures must be byte-comparable; and the
  global `json` does not exist under vanilla Lua, so without this CI could neither
  write nor replay an evidence file. Floats are formatted to round-trip bit-exactly
  (verified against `0.1 + 0.2` and `1.7976931348623157e308`). NaN, infinity, cycles,
  mixed array/map tables and sparse arrays are **rejected with a reason** rather than
  mangled. `decode_lines` isolates damage per line, so one truncated write does not
  discard a whole evidence file.
- `security-forensics/logic/evidence.lua` — append-only store with injected
  persistence. Counts encode failures, backend failures and corrupt lines separately;
  `is_complete()` goes false the moment anything is lost. Incident snapshots
  accumulate rather than replace, so the history of how an assessment evolved
  survives. Path segments are sanitised, because `category` arrives from a record and
  a `../` would otherwise choose where a write lands. An FNV-1a chained digest detects
  accidental corruption — documented explicitly as **not** cryptographic tamper-proofing.
- `security-forensics/logic/investigation.lua` — assembles an incident, its detections
  and its telemetry into a reviewable bundle, and `review()` refuses to call it
  reviewable when the evidence does not support the conclusion.

#### Added — Phase 4 start: the detector registry and detector #1
- `security-detectors/logic/registry.lua` — supports two detector kinds, `record` and
  `periodic`. Posture's subject is the server's configuration rather than a telemetry
  record, and forcing it through `detect(state, record, config)` would have meant
  inventing a fake record to trigger it. A throwing detector is contained, counted and
  disabled after three *consecutive* failures; a success resets the counter so an
  intermittent fault does not accumulate towards a trip. The registry refuses a result
  whose `detector_id` or `detector_version` does not match the registration, so one
  detector cannot emit findings attributed to another and an incident's detector list
  cannot be a lie.
- `security-detectors/logic/server_posture.lua` — detector #1. A pure transform of
  posture findings into `DetectionResult`s, keyed to `SYSTEM` because the subject is
  the server. Confidence is 1.0 and legitimately uncapped: this is a direct read of
  configuration, not an inference about behaviour. An unrecognised severity **raises**
  rather than defaulting to `info`, because defaulting would downgrade a critical
  finding into one that gets ignored.
- Adapters for `security-forensics` and `security-detectors`, plus a file backend for
  the evidence store and codec exports on `security-telemetry`. Every cross-resource
  call passes and returns **plain tables only**, so nothing depends on whether a table
  of functions survives an `exports` call (UNVERIFIED — EXP-010).

#### Added — verification
- `scripts/verify.sh`, `scripts/lint.sh`, `scripts/test.sh`.
- `scripts/check_no_enforcement.lua` — build gate against enforcement and state
  mutation, with a self-test.
- `tests/harness.lua` + **378 unit tests**.

#### Fixed
- **A manifest-ordering test passed on prose.** It searched the manifest for
  `server/main.lua` as a bare substring, and one manifest's comment mentions that path
  while explaining load order — so the match landed in the comment and the assertion
  could not fail. It now matches the quoted entry, and this was verified by
  temporarily mis-ordering a manifest and confirming the test fails.
- **`read()` claimed every retrieval was incomplete.** `complete and nil or
  string.format(...)` always yields the string, because Lua's `and` cannot produce
  nil. The same trap was independently present in a test helper, where it meant the
  write-only backend case was never actually exercised. Both are now explicit `if`
  statements with a comment saying why.
- **`investigation.render()` crashed on a bundle with no review block** — a nil index
  on `review.problems`. A render that throws is worst precisely when it matters, so it
  is now nil-safe throughout and covered by an 11-shape fuzz test. An unassessed
  bundle now reports "not assessed" rather than looking clean.
- **Resource boot would have failed.** The adapters used `require 'lib.mode'`, but FiveM
  has no `require` for resource scripts: `server_scripts` files load as plain chunks into
  one shared per-resource Lua state and the chunk's return value is discarded (R-004).
  CI was green and the resources would not have loaded. Every pure module now
  dual-exports — publishing to a resource-scoped `SecLab` global *and* returning the
  table — so FXServer and vanilla Lua both work with no environment check. Adapters
  `assert` their dependencies, since `fxmanifest.lua` order is now load-bearing.
- Added `tests/unit/test_module_loading.lua`, which simulates FXServer's loading model
  (`loadfile` into a shared environment, return discarded) and checks that each module is
  reachable, functional, and listed in the manifest in the right order. It is the only
  Tier A test that covers the boot path, and it immediately caught a missing
  `fxmanifest.lua` for `security-forensics`.

#### Findings
- **OBSERVATION** — FXServer build 35945 requires a valid `sv_licenseKey`. The
  documented `sv_lan` license-check bypass does **not** work (5 variants tested).
  Recorded as a documentation discrepancy.
- **FACT** — 0 of 6,416 GTA natives are server-callable; 360 of 943 Cfx natives are.
- **FACT** — `GET_PLAYER_CAMERA_ROTATION` and `GET_PLAYER_FOCUS_POS` are server
  natives under OneSync, so aim telemetry needs no trusted client agent.
- **FACT** — `sv_stateBagStrictMode`, `sv_entityLockdown` and
  `sv_filterRequestControl` all default to their permissive settings.
- **OBSERVATION** — vanilla Lua 5.4 rejects CfxLua backtick hash literals and has no
  `vector3`, which forces the pure-logic / thin-adapter split.
- **OBSERVATION** — FiveM resource scripts have no documented `require`, and chunk
  return values are discarded (R-004). Tier A can pass while a resource is unloadable.

#### Notes
- No enforcement of any kind. Detectors are disabled by default.
- **Nothing in this repository has yet run inside FXServer.**

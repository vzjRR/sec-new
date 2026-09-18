# Configuration reference

**Generated from `security-core/lib/config.lua` by `scripts/gen-config-docs.sh`.**
Do not edit by hand — regenerate instead, so this file cannot drift from the schema.

Each key is overridable by a ConVar: `security_` + the key with dots replaced by
underscores. For example `poll.movement_ms` becomes `security_poll_movement_ms`.

An invalid override is **rejected and the default kept**, with the problem logged.
Refusing to boot over one bad config line would leave the server with no
observability at all, which is worse than running with a sane default.

```
detectors.enabled = false  (boolean)
    Detection is OFF by default. Phase 2 is observation only (charter §4).
framework.qbcore = true  (boolean)
    Enable QBCore enrichment. Degrades silently if qb-core is absent.
framework.resolve_retry_ms = 2000  (number)
    Retry interval for resolving a citizenid after playerJoining. There is no DOCUMENTED server-side player-loaded event in QBCore, so we poll rather than depend on an unverified event name (QBCORE_INTEGRATION.md §1).
framework.resolve_timeout_ms = 60000  (number)
    Give up resolving a citizenid after this long; the session stays SRC-keyed.
log_level = info  (string)
    Minimum level written. debug is LAB-only in practice.
mode = PRODUCTION  (string)
    Resolved from the security_mode ConVar. Fails closed to PRODUCTION.
poll.aim_ms = 500  (number)
    Camera rotation sampling. Provisional: the natives update rate is UNMEASURED (EXP-001), so this default is a placeholder, not a finding.
poll.movement_ms = 1000  (number)
    Movement sampling. 1s balances teleport visibility against cost; sub-100ms is refused because it would poll faster than sync updates arrive.
poll.network_ms = 10000  (number)
    Peer statistics refresh only once per 10s server-side (audit §7.5), so polling faster is pure waste. The 5s floor reflects that.
poll.player_state_ms = 5000  (number)
    Health, armour, weapon, vehicle, job.
posture.audit_on_boot = true  (boolean)
    Run the ConVar posture audit at startup.
posture.recheck_ms = 300000  (number)
    ConVars can change at runtime; re-audit occasionally. 5 minutes.
telemetry.buffer_size = 2048  (number)
    Ring buffer capacity before flush. Bounded so a telemetry spike cannot exhaust server memory (charter §15).
telemetry.enabled = true  (boolean)
    Master switch for the telemetry pipeline.
telemetry.sink = jsonl  (string)
    Where normalized records go. memory is for tests.
telemetry.validate_records = true  (boolean)
    Run schema validation on every record. Cheap, and catches adapter bugs before they poison the evidence store.
```

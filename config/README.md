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
detectors.entity_rate.churn_lifetime_ms = 2000  (number)
    An entity removed within this long of creation counts as churn.
detectors.entity_rate.churn_window_ms = 5000  (number)
    Sliding window for counting create/remove churn.
detectors.entity_rate.max_events_per_key = 256  (number)
    Bound on events held per window key.
detectors.entity_rate.max_keys = 512  (number)
    Bound on tracked player/type windows. Eviction is counted and downgrades any detection built on a lossy window (charter §15).
detectors.entity_rate.max_per_window = 0  (number)
    0 = NOT CONFIGURED, no rate detections. Set from an observed baseline once Phase 2 has run on the lab; a guessed value produces false positives.
detectors.entity_rate.max_tracked_entities = 4096  (number)
    Bound on live entity handles tracked for churn pairing.
detectors.entity_rate.min_churn_n = 0  (number)
    0 = NOT CONFIGURED, no churn detections. Needs a baseline like the rate.
detectors.entity_rate.redetect_ms = 30000  (number)
    Minimum gap between repeat detections of the same signal for one player, so a sustained burst is one finding rather than hundreds.
detectors.entity_rate.window_ms = 60000  (number)
    Sliding window for the creation-rate count.
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

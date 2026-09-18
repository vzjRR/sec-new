# D-002 — Append-only JSONL for evidence, not the QBCore MySQL database

- **Date:** 2026-09-18
- **Role:** SECURITY-ARCHITECT
- **Status:** accepted, with a deferred escape hatch

## Decision
Three tiers: FXServer **KVP** for config and counters · append-only **JSONL** files for
telemetry and evidence · **`node:sqlite`** offline for analysis. The platform does **not**
write to the QBCore MySQL database.

## Context
QBCore servers normally run MySQL via `oxmysql`, so using it would be the conventional
choice. The audit found no database server available in the build environment (§5) and
FXServer's built-in KVP store and structured-trace channel (§7.6).

## Rationale
1. **Separation of failure domains.** Security evidence must not share a failure domain
   with gameplay data. If the game database is down or overloaded, the observatory must
   keep recording — that is precisely when incidents are most likely.
2. **Integrity.** Append-only, write-once files are a better forensic record than mutable
   rows. Tamper-evidence comes free.
3. **Testability.** A DB-coupled design would be untestable in CI (no database server),
   which under C2 means untested forever.
4. **The same artifact serves two purposes.** JSONL files are directly replayable as CI
   regression fixtures, which is what makes the knowledge loop mechanical rather than
   aspirational (C3).
5. **No new dependency** on the operator's side.

## Alternatives considered
| Option | Rejected because |
| --- | --- |
| `oxmysql` into the QBCore DB | Shared failure domain; mutable rows; untestable in CI; couples us to the framework we also audit |
| KVP for everything | Not designed for high-volume append; no efficient range queries |
| A separate MySQL instance | Operator burden for no forensic gain |
| SQLite inside the game process | Puts query cost on the server tick |

## Consequences
- Storage volume must be managed — see `PERFORMANCE_BUDGET.md` §4. Rough order for 64
  players/hour: movement ~80 MB, aim ~135 MB. **Too much for continuous production use**,
  so detector-driven sampling is required in Phase 4.
- A `storage` sink interface exists from Phase 2, so adding an `oxmysql` sink later is a
  configuration change rather than a rewrite.
- **Unverified:** whether `io.open` append is available to server-side Lua on the target
  build (**EXP-008**). If not, the sink swaps to KVP batching or an HTTP shipper — the
  interface is why that is cheap.

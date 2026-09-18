# TELEMETRY SCHEMA

**Schema version:** `1`
**Status:** implemented in `resources/[vzjrr-security]/security-telemetry/logic/`, unit-tested in CI.
**Governs:** every record the platform emits. Adapters may not invent their own formats.

---

## 1. Envelope

```lua
{
  schema_version  = 1,            -- integer, bumped on breaking change
  ts              = 1758204000123,-- integer ms, server wall clock (os.time based)
  mono            = 154321,       -- integer ms, monotonic since boot (GetGameTimer)
  seq             = 4711,         -- integer, per-process monotonic sequence
  player_key      = "QB:ABCD1234",-- stable pseudonymous player identity, or "SRC:12"
  src             = 12,           -- transient FiveM server id (net id), may be nil
  category        = "combat",     -- enum, §3
  event           = "weapon_damage",
  source          = "event:weaponDamageEvent",
  measurements    = { ... },       -- numbers only, §4
  context         = { ... },       -- non-numeric qualifiers, §5
  correlation_id  = "c_9f2a1b",   -- links records belonging to one episode
  trust           = "claimed",    -- §6 — provenance of the payload
}
```

### Why both `ts` and `mono`

Wall clock is what an investigator reads; it can jump (NTP, DST). Monotonic time is what
measurements must be computed from, because a backwards clock step would otherwise
manufacture impossible intervals — and impossible intervals look exactly like cheating.
**All timing measurements use `mono`. `ts` is for humans only.** This is a
false-positive control, not bookkeeping.

### Why `seq`

Two records can share a millisecond. `seq` gives a total order for replay and makes
fixture comparison deterministic.

---

## 2. Player identity

`player_key` is the durable key used for baselines, history and incidents.

| Form | When | Stability |
| --- | --- | --- |
| `QB:<citizenid>` | QBCore player loaded | Stable across sessions and characters-per-citizenid |
| `SRC:<src>` | Pre-load, or QBCore unavailable | **Session-only** — never used for history |

QBCore's `citizenid` is the right key: unique, stable, server-generated, and not
personally identifying (see `QBCORE_INTEGRATION.md` §3).

**Never present in telemetry:** real names, `charinfo.firstname`/`lastname`,
`birthdate`, `phone`, `account`, IP addresses, Steam/Discord/license identifiers.
These are reachable server-side (audit §7.4) and are deliberately excluded — they carry
privacy cost and no detection value. Identifier resolution for an *investigation* is a
separate, access-controlled lookup, not a field on every record.

A record may be re-keyed once, when a `SRC:` session is later resolved to a `QB:`
identity; forensics records that rebinding explicitly rather than rewriting history.

---

## 3. Categories

| Category | Meaning |
| --- | --- |
| `combat` | Damage, shots, kills, projectiles, explosions |
| `aim` | Camera/aim geometry and target acquisition |
| `movement` | Position, velocity, transitions |
| `event` | Net-event and callback activity, including our own audit findings |
| `entity` | Entity creation, ownership, removal |
| `economy` | Money, inventory, items, jobs, transactions |
| `player_state` | Health, armour, weapon, vehicle, job, duty |
| `network` | Ping, packet loss, RTT variance |
| `system` | Boot, shutdown, config, mode, health, detector lifecycle |

---

## 4. `measurements` — numbers only

A hard rule: **`measurements` contains only numbers** (or `nil`). Anything non-numeric
belongs in `context`.

This exists so that statistics, baselines and the SQLite analysis layer can treat the
field generically — sum it, bucket it, compute variance — without per-event special
casing. It is what lets `STATISTICS_ENGINEER` work over the whole corpus rather than
per-detector.

Units are explicit in the key name, always. `_ms`, `_m`, `_mps`, `_deg`, `_pct`, `_n`.
An unlabelled number is a bug.

```lua
measurements = {
  damage_n        = 35,
  distance_m      = 42.7,
  delta_ms        = 118,
  speed_mps       = 6.2,
  angle_deg       = 12.4,
  packet_loss_pct = 0.8,
}
```

---

## 5. `context` — qualifiers

Non-numeric, low-cardinality descriptors. Enumerations and hashes, not free text.

```lua
context = {
  weapon_hash   = 453432689,
  hit_component = 3,
  silenced      = false,
  in_vehicle    = true,
  bucket        = 0,
  will_kill     = false,
  target_key    = "QB:EFGH5678",
  mode          = "LAB",
}
```

High-cardinality or unbounded strings (chat text, resource-supplied payloads) are not
permitted here. They blow up storage, leak PII, and are rarely the signal.

---

## 6. `trust` — provenance, carried per record

This field is unusual and it is the schema's most important idea.

| Value | Meaning | Example |
| --- | --- | --- |
| `observed` | Server computed it from its own state | `GET_ENTITY_COORDS`, `GET_PLAYER_PING` |
| `claimed` | Attacker-influenced payload the server merely routed | `weaponDamageEvent` fields, net-event args |
| `derived` | We computed it from other records | a rate, a delta, a baseline |
| `framework` | QBCore's server-side view | `PlayerData.money`, `job.onduty` |

Carrying provenance *per record* means a detector cannot accidentally treat a client's
claim as a server fact — the distinction is in the data, not in a comment. It also means
an investigator reading an incident can see immediately which parts of the story the
attacker controlled. Audit §5 of `TRUST_BOUNDARY.md` explains why this matters more than
it first appears.

**Rule:** a detection that rests solely on `claimed` measurements may not exceed
`confidence = 0.5`. Raising confidence requires at least one `observed` corroboration.
This is enforced in `DETECTION_MODEL.md` and checked in tests.

---

## 7. Correlation

`correlation_id` groups records into one episode so a timeline can be reconstructed
(charter `§11`, `§12`). Assignment rules:

- A combat engagement: shared id for the duration of contact between two players,
  expiring after a configured idle gap.
- A connection session: shared id from `playerJoining` to `playerDropped`.
- A detector's own output: inherits the id of the record that triggered it.
- A scenario run in LAB: the scenario id becomes the correlation prefix.

---

## 8. Storage format

One JSON object per line, UTF-8, LF-terminated, append-only:

```
telemetry/2026-09-18/combat.jsonl
telemetry/2026-09-18/movement.jsonl
```

Append-only and plain text is chosen for forensic and testing reasons both: it is
write-cheap on the hot path, naturally ordered, tamper-evident by being write-once, and
directly replayable as a CI fixture (`ARCHITECTURE.md` §2 C3).

---

## 9. Versioning

`schema_version` is an integer. Additive changes (a new optional measurement, a new
category) do **not** bump it. Removing or re-typing a field, or changing a unit, **does**.

On a bump: the reader must handle both versions, the previous version's fixtures stay in
the regression suite, and the change gets a `knowledge/decisions/` entry. Fixtures are
never rewritten to match new code — that would destroy the regression signal.

---

## 10. Validation

`validate(record)` in `logic/schema.lua` returns `ok, errors`. It checks envelope
completeness, category and trust enums, `measurements` numeric-only, `context`
non-numeric-key sanity, and unit suffixes on measurement keys. CI runs it over every
committed fixture, so a schema violation cannot be merged.

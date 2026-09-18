# `entity.rate` — client entity creation rate and provenance

- **Status:** design. **Not blocked** — the first behavioural detector that can be
  implemented without an experiment.
- **Planned order:** detector #3
- **Version:** 1 (planned)

## Objective

Detect abnormal rates and provenance of client-created entities — the mechanism behind
vehicle, ped and object spawn abuse.

## Read this first: configuration comes before detection

`sv_entityLockdown` **defaults to `inactive`**, which the official documentation
describes as "clients can create any entity". On a default server, spawn abuse is not a
cheat to be detected — it is a **permitted operation**.

So `POSTURE-004` reports the ConVar, with `strict` and `relaxed` both explained. This
detector exists for what remains after hardening: a server running `relaxed` (because
some resource needs client entities) still has a surface worth watching.

Recommending this detector to an operator on an `inactive` server would be advising them
to monitor a door they have left open. Fix the door first.

## Telemetry consumed

| Source | Trust | Notes |
| --- | --- | --- |
| `entityCreating` / `entityCreated` / `entityRemoved` | **observed** — the server routed it | |
| `GET_ENTITY_TYPE`, `GET_ENTITY_MODEL`, `GET_ENTITY_POPULATION_TYPE` | **observed** | |
| `GET_ENTITY_SCRIPT` | **observed** | The key field: which resource, if any, owns the entity |
| `GET_ENTITY_ROUTING_BUCKET` | **observed** | |
| Creation rate per window | **derived** from observed arrival times | The attacker does not control our clock |

**Known gap:** `entityCreating` carries only a handle, and `NetworkGetEntityOwner` is
client-side, so **owner attribution is not directly available**. Current adapters
correctly leave it `nil` rather than guessing. Attribution must be inferred — see
Blockers.

## Signal definition

1. **Creation rate** — entities created per `player_key` per bounded window, split by
   entity type.
2. **Scriptless creation** — `GET_ENTITY_SCRIPT` empty on a server where every
   legitimate spawner sets one.
3. **Model-class anomaly** — a model outside the classes this server's gameplay ever
   spawns (per-server allowlist).
4. **Churn** — rapid create/remove cycles, which look like probing or like an attempt to
   stay under a rate threshold.
5. **Population-type mismatch** — a `POPTYPE_*` inconsistent with how the entity appeared.

## Thresholds and justification

Rates must come from **this server's own observed baseline**, not a guess. A racing
server spawns vehicles constantly; a roleplay server barely does. Ship with detection
disabled, collect a baseline, then set thresholds at a documented percentile of the
observed per-player distribution.

Churn is the one signal with a defensible a-priori shape: create-then-remove within a
few hundred milliseconds, repeated, has no legitimate gameplay analogue this project
is aware of. Even so it needs a baseline before it fires.

## Confidence model

| Signal | Confidence | Reasoning |
| --- | --- | --- |
| Scriptless creation on a server where all spawners set a script | **0.7** | Server-observed and structurally odd; capped below higher values because "all spawners set a script" is an assumption about the installed resource set. |
| Rate above baseline | **0.5** | Rates are observed, but legitimate bursts exist (a garage, a convoy, an event). |
| Churn | **0.6** | Distinctive shape, but needs repetition. |
| Model-class anomaly | **0.4** | Allowlists go stale; a new resource legitimately introduces models. |

All bases `observed` or `derived`, so the claimed-only cap does not bind.

## False-positive analysis

| Cause | Handling |
| --- | --- |
| Legitimate spawners (`qb-garages`, `qb-vehicleshop`, job scripts, admin menus) | Check `GET_ENTITY_SCRIPT` and exempt known resources; check `HasPermission` for admin activity. |
| A server event spawning many entities at once | Rate windows must be per player, and server-side spawns are not attributed to a player at all. |
| A new resource introducing unknown models | Model-class checks stay low confidence and are advisory. |
| Reconnect or bucket change re-creating entities | Bucket transitions invalidate continuity, as with movement. |
| `relaxed` lockdown where non-script client entities are expected | Configurable exemptions, documented per server. |

## Performance budget

O(1) per entity event: 4–5 native reads plus a counter increment. Event-driven, so the
cost tracks real activity.

**Watch:** on a busy server `entityCreated` can be frequent. `GET_ALL_*` enumeration is
explicitly **not** used per event — only on a slow timer, if at all.

## Scenarios

| ID | Setup | Expected |
| --- | --- | --- |
| `ENTITY-001` | Burst of client vehicle creation | rate violation |
| `ENTITY-002` | Create entities with no owning script | scriptless finding, ~0.7 |
| `ENTITY-003` | Rapid create/remove cycling | churn finding |
| `ENTITY-004` | **Legitimate:** garage retrieval, vehicle shop purchase, job spawns | **no detections** |
| `ENTITY-005` | **Legitimate:** admin spawning via the admin menu | **no detections** |
| `ENTITY-006` | **Legitimate:** a server-run event spawning many entities | **no detections** |

## Blockers

None for a first implementation of signals 1, 3 and 4. Two things must be resolved
before it is trusted:

1. **Owner attribution.** Without it, a rate cannot always be tied to a `player_key`.
   Candidate approach: correlate an `entityCreating` with the nearest player by
   server-observed position and scope, and record the attribution method and its
   confidence **in the record**. An unattributed creation must be recorded as
   unattributed rather than assigned to a guess.
2. **A population baseline** for the rate threshold (needs Phase 2 running on the lab).

Signal 2 additionally needs `EXP-006` to establish whether every legitimate spawner on
this server does in fact set an entity script.

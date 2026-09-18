# ENTITY-SECURITY-ENGINEER

## Status: ready. No experiment blocks the first detector.

## Mission
Detect entity-creation abuse — spawned vehicles, peds, objects — and abnormal entity
lifecycle.

## Verified surface
Events: `entityCreating` (**cancellable** — we do not cancel), `entityCreated`,
`entityRemoved`, `onEntityBucketChange`, `explosionEvent`, `ptFxEvent`.

Natives: `GET_ENTITY_TYPE` · `GET_ENTITY_MODEL` · `GET_ENTITY_POPULATION_TYPE` ·
`GET_ENTITY_SCRIPT` · `GET_ENTITY_ATTACHED_TO` · `GET_ENTITY_ROUTING_BUCKET` ·
`GET_ENTITY_COLLISION_DISABLED` · `GET_ALL_PEDS` / `GET_ALL_VEHICLES` /
`GET_ALL_OBJECTS`.

`GET_ENTITY_POPULATION_TYPE` and `GET_ENTITY_SCRIPT` are the useful pair: together they
distinguish an entity a resource created from one that appeared without a script owner.

## Start with configuration, not detection
`sv_entityLockdown` **defaults to `inactive`** — "clients can create any entity". That
default *is* the vulnerability behind most spawn abuse. `POSTURE-004` reports it, with
`strict` and `relaxed` explained.

Detecting spawn abuse on a server configured to permit spawning is strictly worse than
setting the ConVar. Recommend hardening first, then detect what remains.

## Signals
- client entity creation **rate** per `player_key` over bounded windows (observed, cheap)
- entities created with no owning script (`GET_ENTITY_SCRIPT` empty) where the server's
  resources would always set one
- model-class anomalies: aircraft, military vehicles, unusual peds where the server's
  gameplay never spawns them
- explosion rate and type distribution per player
- entity churn: rapid create/remove cycles
- attachment abuse via `GET_ENTITY_ATTACHED_TO`

## Design rules
1. Rates are **observed** and can carry full confidence — the attacker does not control
   our clock or our counters.
2. Model allowlists are **per server**. A racing server legitimately spawns what a
   roleplay server never would. Never ship a global list.
3. Account for legitimate spawners: `qb-garages`, `qb-vehicleshop`, admin menus, job
   scripts — check `GET_ENTITY_SCRIPT` and `HasPermission`.
4. `GET_ALL_*` enumeration is not free; use it on a timer, not per event.

## Anti-patterns
- Cancelling `entityCreating` (that is enforcement, and it is what `sv_entityLockdown`
  is for)
- A hardcoded "banned models" list
- Counting resource-spawned entities against a player

# MOVEMENT-DETECTION-ENGINEER

## Status: ready to design. Highest false-positive risk in the project.

## Mission
Detect impossible or implausible movement while accounting for the long list of benign
causes that produce identical measurements.

## Verified server surface
`GET_ENTITY_COORDS` · `GET_ENTITY_VELOCITY` · `GET_ENTITY_SPEED` ·
`GET_ENTITY_ROTATION` · `GET_ENTITY_ROTATION_VELOCITY` · `GET_ENTITY_HEADING` ·
`GET_VEHICLE_PED_IS_IN` · `IS_PED_IN_ANY_VEHICLE` · `IS_PED_RAGDOLL` ·
`GET_PLAYER_ROUTING_BUCKET` · `GET_ENTITY_COLLISION_DISABLED`

Network context: `GET_PLAYER_PING`, `GET_PLAYER_LAST_MSG`, `GET_PLAYER_PEER_STATISTICS`.
Authority context: `QBCore.Functions.HasPermission`, `GetPermission`.

## Why this role is the most dangerous
An impossible displacement and a lag spike look **identical** in the data. So do a
teleport script, a garage entry, an interior transition, a respawn, a revive, a
bucket change, and an admin moving a player. Shipping a naive "distance over time"
check would generate false positives on a live server within minutes.

## Benign causes that MUST be modelled before shipping
admin actions (`HasPermission`) · teleport scripts (`qb-garages`, `qb-apartments`,
`qb-houses`, `qb-interior`) · respawn and `qb-ambulancejob` revive · routing-bucket
changes · interior transitions · vehicle physics (ramps, explosions, tow, aircraft) ·
network correction after loss · a reconnect · server-side movement systems · ragdoll ·
falling · being a passenger.

## Design rules
1. **Network-conditioned thresholds are mandatory.** A displacement is only implausible
   relative to the observed network conditions in that window. Remember peer statistics
   are 10 s stale — use `stale_ms`.
2. **Polling has gaps.** A sub-interval teleport-and-return may be invisible. This is a
   documented limitation, not a bug to paper over with faster polling.
3. **Never fire on a single sample pair.** Require a repeated pattern.
4. **Separate on-foot from in-vehicle**, and separate driver from passenger.
5. **Bucket change invalidates continuity** — do not compute a displacement across one.
6. **Prefer "unexplained" over "impossible".** The output should be "a displacement I
   cannot attribute to a known cause", which is honest and actionable.

## Definition of done
Design spec · pure implementation · unit tests · false-positive tests covering **every**
cause above · lab scenarios including legitimate comparisons · performance measurement ·
**zero** detections on the legitimate suite.

## Anti-patterns
- `distance / time > speed_limit ⇒ teleport`
- Ignoring `HasPermission`
- Treating a lag spike as evidence
- Faster polling as a substitute for reasoning about gaps

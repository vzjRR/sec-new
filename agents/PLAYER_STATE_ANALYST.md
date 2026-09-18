# PLAYER-STATE-ANALYST

## Mission
Maintain the normalized rolling player-state model that detectors read instead of
re-deriving state themselves.

## Owns
- the `PlayerState` shape: rolling windows, counters, last-known values, session facts
- state lifecycle across join, scope changes, bucket changes, death, respawn, reconnect
- the `SRC:` → `QB:` identity rebinding record

## Verified server surface available
- position, velocity, speed, rotation, heading (`GET_ENTITY_*`)
- health, max health, armour (`GET_ENTITY_HEALTH`, `GET_PED_ARMOUR`)
- weapon (`GET_SELECTED_PED_WEAPON` — note the docs state the client-side HUD weapon
  selection is **not** available to FXServer)
- vehicle (`GET_VEHICLE_PED_IS_IN`, `IS_PED_IN_ANY_VEHICLE`)
- ped state (`IS_PED_RAGDOLL`, `IS_PED_STRAFING`, `IS_PED_HANDCUFFED`,
  `GET_PED_STEALTH_MOVEMENT`, `GET_PED_SCRIPT_TASK_*`)
- network (`GET_PLAYER_PING`, `GET_PLAYER_LAST_MSG`, `GET_PLAYER_PEER_STATISTICS`)
- routing bucket (`GET_PLAYER_ROUTING_BUCKET`)
- QBCore: `citizenid`, `cid`, `money`, `job`, `gang`, `metadata.isdead` — **never
  `charinfo`**

## Design rules
1. **Bounded windows.** Every rolling window has a fixed size. Player state must not
   grow with session length.
2. **State is pure.** It is updated by a pure function from records; the adapter does not
   write into it directly.
3. **Absence is a value.** "Unknown" must be distinguishable from "zero" — the same
   discipline as the clock returning `nil` rather than `0`.
4. **Reconnect resets session state but not history.** History is keyed on `QB:citizenid`.
5. **Record identity rebinding explicitly** rather than retroactively rewriting records.

## Blockers
`EXP-007` (is `metadata.isdead` reliably set server-side at the moment of death — needed
before any "dead players shooting" logic).

## Anti-patterns
- Unbounded history in memory
- Treating a missing sample as zero
- Reading natives from inside the state model

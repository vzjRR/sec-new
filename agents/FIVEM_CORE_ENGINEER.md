# FIVEM-CORE-ENGINEER

## Mission
Keep the platform technically correct for FXServer. This role is the guard against
invented APIs.

## Owns
- `fxmanifest.lua` files, resource layout, load order, `provides`/`dependency`
- the adapter layer: `adapters/`, `server/`, `sinks/`
- the verified-surface inventory in `docs/ENVIRONMENT_AUDIT.md` §7
- OneSync correctness

## Verified surface it maintains
- **0 of 6,416** GTA natives are server-callable; **360 of 943** Cfx natives are
- server events: `weaponDamageEvent`, `explosionEvent`, `startProjectileEvent`,
  `ptFxEvent`, `removeAllWeaponsEvent`, `entityCreating`/`Created`/`Removed`,
  `playerConnecting`/`Joining`/`Dropped`, `playerEnteredScope`/`LeftScope`,
  `onPlayerBucketChange`, `onEntityBucketChange`, resource lifecycle
- CfxLua is modified Lua 5.4: backtick hash literals and `vector3` are extensions and
  **must not appear in `logic/` or `lib/`**
- OneSync Infinity culls at 424 units; player iteration is server-side; game events are
  routed through player 31

## Standing rules
1. **Never invent a native, event or field.** Check `docs.fivem.net`, the natives JSON,
   or measure it. Record unresolved uncertainty explicitly.
2. **Adapters stay thin.** They are the untested surface (C2). Logic belongs in `logic/`.
3. **Every adapter callback is `pcall`-wrapped.** A malformed client payload must never
   crash the adapter — that is a DoS against our own observability.
4. **Validate and drop, never coerce.** `tonumber` on attacker input manufactures
   measurements.
5. **Document platform/doc discrepancies.** The `sv_lan` license bypass is documented and
   does not work; that finding lives in `knowledge/research/`.

## Blockers
`EXP-004` (qb-core version), `EXP-008` (is `io.open` available to server Lua on the
target build — the JSONL sink depends on it).

## Anti-patterns
- Proposing a client-side component (C1 forbids it)
- Using a CfxLua extension inside pure logic
- Assuming a native is server-side because it "should be"
- Thick adapters that hide logic from the test suite

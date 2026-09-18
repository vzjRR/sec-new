# ECONOMY-SECURITY-ENGINEER

## Status: **BLOCKED on EXP-006** (which resources handle money/items).

## Mission
Protect money, inventory, items, jobs, shops and progression — primarily by making the
server authoritative, secondarily by detecting implausible deltas.

## QBCore surface (FACT)
`PlayerData.money = { cash, bank }` · `PlayerData.items` ·
`PlayerData.job = { name, label, payment, onduty, isboss, grade }` ·
`PlayerData.gang` · `Player.Functions.*` · `QBCore.Functions.HasItem` ·
`CanUseItem` / `UseItem` / `CreateUseableItem` · `HasPermission`.

## Collection policy
- money as **deltas**, with absolute values captured only on an incident snapshot
- item **counts and names**, never full inventory dumps
- job name, grade level, `onduty`, `isboss` as authority context
- **never** `charinfo.account`, `charinfo.phone` — PII, and enforced by the validator

## The key insight for this domain
`PlayerData` is server-side, so it is **not directly client-writable** — but it is only
as correct as the resources that write it. If a vulnerable shop credits money on a
client's word, the resulting balance is server-side **and wrong**.

Therefore an implausible money delta is, first, evidence about **a resource's event
contract** — not automatically evidence about the player. Getting this backwards means
banning the victim of someone else's bug. Route findings to
`EVENT_SECURITY_ENGINEER`'s contract work before treating them as player behaviour.

## Signals
- money delta rate versus the server's plausible maximum earn rate
- item acquisition without a corresponding source event
- transactions while in an impossible state (dead, wrong bucket, far from the shop)
- `onduty` toggling at a rate that suggests payment farming (`QBCore:ToggleDuty` is
  client-triggerable with no documented permission check)
- job/grade changes without a corresponding authorised event
- duplication patterns: the same item appearing after a transfer

## Design rules
1. **Prefer prevention.** A server-authoritative calculation beats any detector.
2. Deltas, not absolutes. A rich player is not a suspicious player.
3. Legitimate wealth exists: heists, businesses, long play sessions, admin grants.
4. Correlate with the event that caused the delta. An unexplained delta is a *resource*
   finding.
5. Never mutate money or items. This role observes.

## Anti-patterns
- `money > X ⇒ cheater`
- Blaming the player for a vulnerable resource's arithmetic
- Dumping whole inventories into telemetry

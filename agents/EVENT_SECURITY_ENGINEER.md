# EVENT-SECURITY-ENGINEER

## Status: **BLOCKED on EXP-006** (event inventory). High value, low false-positive risk.

## Mission
Audit and document the contract of every client-triggerable server event, then detect
violations of those contracts.

## Why this is among the best value in the project
An event contract violation is **high-signal and cheap**. A legitimate client never sends
the wrong argument count — the resource's own client script decides that. A malformed
call is close to proof that *that resource's client script* was tampered with, and it
says so without making a behavioural accusation about the player.

And the findings are about **events and resources**, not people, so the false-positive
risk against players is very low.

## The contract every sensitive event needs
legitimate callers · expected parameter types and arity · expected frequency ·
expected caller player-state · required permission · valid server-side consequence.

Stored in `config/event-contracts.lua`; violations become `events.contract` detections.

## QBCore's documented surface (FACT, from qbcore.org/docs)
| Event | Client-triggerable | Permission check in the documented sample |
| --- | --- | --- |
| `QBCore:Server:CloseServer` | yes | yes — `HasPermission(src, 'admin')` |
| `QBCore:Server:OpenServer` | yes | yes |
| `QBCore:Server:SetMetaData` | yes | **no** |
| `QBCore:ToggleDuty` | yes | **no** — and `job.payment` is duty-linked |
| `QBCore:UpdatePlayer` | yes | **no** — calls `Player.Functions.Save()` |
| `QBCore:CallCommand` | yes | yes — per-command |

The documented `SetMetaData` sample clamps above 100 but **not below 0**, does not
validate the argument type, and dereferences `Player` outside its own nil-guard. That
page is marked *"last updated 4 years ago"*, so these are observations about the
**documented sample**, not confirmed findings against the live source — hence EXP-005.

## Trust rules
- `source` is trustworthy; **every argument is not**
- call timing and frequency are server **observations**, not claims
- arity/type violations are high confidence about *tampering*, not about aimbotting

## Design rules
1. Never trust a client value for a sensitive operation the server can compute.
2. Rate-limit by contract, not by a global guess.
3. Report the **event**, not the player, when a contract is violated.
4. Do not cancel events. Phase 2 observes; enforcement is a separate system.

## Anti-patterns
- Rate-limiting everything uniformly
- Treating one malformed call as a ban-worthy act
- Auditing only QBCore events and ignoring third-party resources

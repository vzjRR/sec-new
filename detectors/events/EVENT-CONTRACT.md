# `events.contract` — net-event contract violations

- **Status:** design. **BLOCKED on EXP-006** (event inventory).
- **Planned order:** detector #2 (`docs/DETECTION_MODEL.md` §7)
- **Version:** 1 (planned)

## Objective

Detect calls to server net events that violate the event's declared contract — wrong
arity, wrong argument types, impossible frequency, or an impossible caller state.

## Why this is #2

It is the highest-value behavioural detector available, for a reason that is easy to
miss: **a legitimate client never sends the wrong number of arguments.** The resource's
own client script decides the arity. A malformed call is therefore close to proof that
*that resource's client script was tampered with* — and it says so without making any
claim about the player's aim, reflexes or skill.

And crucially the finding is about **an event and a resource**, not a person. That keeps
false-positive risk against players very low, the same property that puts the posture
audit first.

## Telemetry consumed

| Source | Trust | Notes |
| --- | --- | --- |
| Net-event invocation: name, arity, argument types | **observed** for the envelope | The server observed *that* the call arrived, when, and with how many arguments |
| Argument **values** | **claimed** | Attacker-chosen; only used for type/shape checks, never as a measurement |
| `source` | **observed** | Server-assigned, not client-supplied |
| Caller state (`metadata.isdead`, `job.onduty`, bucket, coords) | **observed** / **framework** | Establishes whether the call was possible |
| `HasPermission` | **framework** | Distinguishes an admin action |

New telemetry needed: an `event`-category record per monitored invocation, carrying
`event_name`, `arity_n`, an argument **type signature** (not values), and the caller's
state at the time. The type signature is the novel part and must be low-cardinality —
e.g. `"number,string,table"` — so it stays a `context` qualifier rather than unbounded
data.

## Contract source

`config/event-contracts.lua`, one entry per monitored event:

```lua
['QBCore:Server:SetMetaData'] = {
  arity       = 2,
  types       = { 'string', 'number' },
  max_per_min = 30,
  requires    = { alive = true },
  permission  = nil,
}
```

Contracts are **per server**, because the installed resource set differs. EXP-006
enumerates what is actually registered; nothing is shipped as a universal default.

## Signal definition

Per `(player_key, event_name)` over a bounded window:

1. **Arity violation** — `#args ~= contract.arity`
2. **Type violation** — positional type mismatch against `contract.types`
3. **Frequency violation** — invocations per minute exceeds `max_per_min`
4. **State violation** — caller state contradicts `contract.requires` (e.g. a shop
   transaction while `metadata.isdead == true`)
5. **Unknown-event invocation** — a net event called that no contract covers *and* no
   installed resource registers

## Thresholds and justification

| Check | Threshold | Justification |
| --- | --- | --- |
| Arity | exact | Not a threshold. The client's own script fixes the arity; any deviation is a deviation. |
| Types | exact, positional | Same reasoning. |
| Frequency | per-contract `max_per_min` | **Must be measured per event, not guessed.** A UI-driven event may legitimately fire several times a second while the player clicks; a save event should fire rarely. EXP-006 provides the observed baseline. |
| State | per-contract | Derived from what the event's own server handler assumes. |

## Confidence model

| Violation | Confidence | Reasoning |
| --- | --- | --- |
| Arity / type | **0.85** | Server-observed envelope, and the client's own script determines both. Not 1.0: a resource update can legitimately change an arity, so a stale contract is the realistic false positive. |
| State | **0.7** | Server-observed, but state sampling has gaps and a race at the moment of death is plausible. |
| Frequency | **0.5** | Genuinely noisy — lag, retries, and UI spam all inflate a rate. |
| Unknown event | **0.4** | Could equally mean our inventory is stale. |

All bases are `observed`, so the claimed-only cap does not bind. Nothing here uses an
uncharacterised native.

## False-positive analysis

| Cause | Handling |
| --- | --- |
| **A resource update changed the contract** | The most likely false positive by far. Mitigation: contracts carry the resource version they were derived from, and a mismatch downgrades the finding to `info` with a "re-derive contracts" note rather than accusing the player. |
| Admin tooling calling events unusually | `HasPermission` / `GetPermission` checked; an authorised caller is exempt or downgraded. |
| Lag and client retries inflating a rate | Frequency checks require the window to be network-conditioned; peer statistics are 10 s stale so `stale_ms` must be consulted. |
| Legitimate UI spam | Per-event `max_per_min` from observation, not a global default. |
| A race at the moment of death | State violations use a grace window rather than an instant. |
| Another resource legitimately triggering an event server-side | Only **client-originated** invocations are evaluated; a server-side `TriggerEvent` has no `source` in the same sense. |

**Unhandled and documented:** an attacker who calls every event with exactly the right
arity, types, rate and state is invisible to this detector. That is the ceiling of a
contract check, and it is still a meaningful bar to clear.

## Performance budget

O(1) per monitored invocation: a table lookup, an arity compare, up to a few type
compares, and a counter increment. Counters are per `(player_key, event)` in bounded
windows, evicted on `playerDropped`. The cost scales with event traffic, which is the
correct shape — no polling.

Risk: a very chatty event could make this the hottest path in the platform. Mitigation:
contracts opt **in** per event; the monitored set is deliberately small and justified.

## Scenarios

| ID | Setup | Expected |
| --- | --- | --- |
| `EVENT-001` | Call a monitored event with wrong arity | arity violation, ~0.85 |
| `EVENT-002` | Call with wrong argument types | type violation |
| `EVENT-003` | Call at 10× the contract rate | frequency violation, ~0.5 |
| `EVENT-004` | Call a transaction event while dead | state violation |
| `EVENT-005` | **Legitimate:** normal play exercising every monitored event | **no detections** |
| `EVENT-006` | **Legitimate:** admin using admin tooling | **no detections** |
| `EVENT-007` | **Legitimate:** the same events under 300 ms ping and 5% loss | **no detections** |

## Blockers

`EXP-006` — which resources are installed, which register client-triggerable events that
mutate server state, and what each event's legitimate arity, types and frequency are.
Without it every contract would be invented, and an invented contract generates false
positives on day one.

`EXP-005` — whether QBCore's documented `SetMetaData` weaknesses exist in the live
source, which decides whether that event is a priority target.

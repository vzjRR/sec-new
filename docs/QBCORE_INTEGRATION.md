# QBCORE INTEGRATION

**Framework:** QBCore (`qb-core`), confirmed by the owner 2026-09-18.
**Posture:** optional, loosely coupled, read-mostly. QBCore is both a *telemetry source*
and a *subject of security review*.

Everything tagged **FACT** below comes from the official QBCore documentation
(`qbcore.org/docs`). Everything tagged **UNVERIFIED** must be checked against the actual
`qb-core` on the owner's server before code depends on it — per charter `§20`, we do not
invent framework APIs any more than we invent natives.

---

## 1. How we obtain the core

**FACT** — as of `qb-core` 1.3.0, all core functions are exported individually and the
whole core object no longer needs importing:

```lua
-- documented, preferred: single function, no core import
local Player = exports['qb-core']:GetPlayer(source)

-- documented: selective core import
local QBCore = exports['qb-core']:GetCoreObject({ 'Functions' })

-- documented but discouraged by QBCore's own docs: full import
local QBCore = exports['qb-core']:GetCoreObject()
```

QBCore's docs state the selective form "was made to reduce the amount of memory being
stored inside each script because importing the full core brought a lot of overhead".

**Our choice: `exports['qb-core']:GetPlayer(source)`, called through a guarded wrapper.**
Reasons: smallest surface, lowest memory, and — most importantly — a security resource
should not hold a live reference to the whole framework object it may later need to
report on.

**Degradation is mandatory, not optional.** The wrapper wraps the export call in
`pcall`. If `qb-core` is missing, stopped, or older than 1.3.0, framework enrichment is
disabled, a `system` telemetry record notes it once, and health output reports
`framework: unavailable`. Core FiveM telemetry is unaffected — it never needed QBCore.

**UNVERIFIED:** the actual `qb-core` version on the owner's server. `EXP-004` (§6) reads
it from `fxmanifest.lua`. Until then the code must tolerate both the export path and its
absence, which it does.

---

## 2. PlayerData we consume

**FACT** — documented `PlayerData` structure:

```
citizenid : string   -- unique identifier, generated via CreateCitizenId
cid       : number   -- character id
money     : { cash: number, bank: number }
charinfo  : { firstname, lastname, birthdate, gender, nationality, phone, account }
job       : { name, label, payment, onduty, isboss, grade: { name, level } }
gang      : { name, label, isboss, grade: { name, level } }
metadata  : { hunger, thirst, stress, isdead, ... }
position  : vector3
items     : table    -- inventory
```

Our field-by-field policy:

| Field | Collected? | Why |
| --- | --- | --- |
| `citizenid` | **yes** — as `player_key` | Stable, opaque, non-identifying |
| `cid` | yes | Distinguishes characters |
| `money.cash`, `money.bank` | yes, as **deltas** | Economy integrity; absolute values only on incident snapshot |
| `job.name`, `job.grade.level`, `job.onduty` | yes | Permission and plausibility context |
| `job.isboss`, `gang.*` | yes | Authority context for economy checks |
| `metadata.isdead` | yes | Critical combat context — dead players should not shoot |
| `metadata.hunger/thirst/stress` | no | No detection value |
| `items` | **counts and item names only** | Inventory integrity without dumping contents |
| `position` | no — we use `GET_ENTITY_COORDS` | Server-observed beats framework-reported (`trust: observed` vs `framework`) |
| `charinfo.*` | **never** | PII: real-world-shaped names, birthdate, phone, bank account. No detection value, real privacy cost. |

`charinfo` exclusion is a hard rule enforced by a test: a PII key appearing anywhere in
a telemetry record fails CI.

---

## 3. Why `citizenid` is the player key

It is unique per the docs ("A unique identifier for the player"), server-generated,
stable across sessions, and opaque. Compare the alternatives:

| Candidate | Problem |
| --- | --- |
| `source` / net id | Recycled every reconnect — useless for history |
| Steam / license / Discord id | Personally identifying; the audit (§7.7) notes `sv_authMaxVariance` defaults to 5, meaning identifiers are *expected* to change |
| `charinfo.phone` / `account` | PII, and player-visible |
| **`citizenid`** | Stable, opaque, server-side, purpose-built |

So `player_key = "QB:" .. citizenid`, with `"SRC:" .. src` as a session-only fallback
that is never written to long-term history (`TELEMETRY_SCHEMA.md` §2).

---

## 4. QBCore as a subject of review

This is where a QBCore-specific security platform earns its keep. QBCore exposes
**client-triggerable net events that mutate server-side state**. Per charter
`EVENT-SECURITY-ENGINEER`, each needs a documented contract: legitimate callers,
expected parameters, expected frequency, expected player state, required permissions.

**FACT** — documented server events (`qbcore.org/docs/qb-core/server-event-reference`):

| Event | Client-triggerable | Permission check in documented sample | Notes |
| --- | --- | --- | --- |
| `QBCore:Server:CloseServer` | yes | **yes** — `HasPermission(src, 'admin')` | Kicks the caller if unauthorised. Good pattern. |
| `QBCore:Server:OpenServer` | yes | **yes** — `HasPermission(src, 'admin')` | Same. |
| `QBCore:Server:SetMetaData` | yes | **no** | Sets player metadata. See §4.1. |
| `QBCore:ToggleDuty` | yes | **no** | Toggles `job.onduty`; `job.payment` is duty-linked. |
| `QBCore:UpdatePlayer` | yes | **no** | Recomputes hunger/thirst and calls `Player.Functions.Save()`. |
| `QBCore:CallCommand` | yes | **yes** — per-command `HasPermission` | Invokes a registered command callback. |

### 4.1 `QBCore:Server:SetMetaData` — the documented sample's own weaknesses

The documentation's sample implementation is:

```lua
RegisterNetEvent('QBCore:Server:SetMetaData', function(meta, data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    if meta == 'hunger' or meta == 'thirst' then
        if data > 100 then data = 100 end
        if Player then Player.Functions.SetMetaData(meta, data) end
    end
    TriggerClientEvent('hud:client:UpdateNeeds', src,
        Player.PlayerData.metadata['hunger'], Player.PlayerData.metadata['thirst'])
end)
```

Reading only what is on the page, three issues are visible:

1. **No lower bound.** `data` is clamped above 100 but not below 0. A client may send a
   negative value.
2. **No type validation.** `data > 100` compares an unvalidated client value; a string or
   table argument raises a Lua error inside the handler.
3. **`Player` dereferenced outside its own nil-guard.** The `TriggerClientEvent` line
   reads `Player.PlayerData` after the `if Player then ... end` block has closed.

**Important caveat, stated plainly:** this page is marked *"Last updated 4 years ago"*,
so the live `qb-core` source may well differ. These are observations about **the
documented sample**, not confirmed findings against the owner's server. `EXP-005` (§6)
verifies them against the real source. The general point stands regardless of what the
current source says: **client-triggerable events that mutate server state are the primary
QBCore attack surface, and enumerating them is Phase 4 work with zero false-positive
risk against players** — the same reasoning that puts the ConVar audit first
(audit §7.7).

### 4.2 The event-audit detector

Consequently the first QBCore-specific detector is an **event inventory and contract
auditor**, not a behavioural one:

- enumerate net-event handlers registered on the server
- for each, record the declared contract from `config/event-contracts.lua`
- observe actual call frequency, argument arity and caller player-state per
  `player_key`
- flag calls that violate the declared contract — wrong arity, wrong types,
  impossible frequency, impossible caller state (e.g. `metadata.isdead == true`)

This produces evidence about **events**, not accusations about players, so it is safe to
ship early and it hardens the server even when no one is cheating.

---

## 5. Functions we use

**FACT** — documented server functions relevant to us:

| Function | Use |
| --- | --- |
| `QBCore.Functions.GetQBPlayers()` | Iterate active players. Docs mark plain `GetPlayers()` deprecated. |
| `QBCore.Functions.GetPlayer(source)` | Player object + `PlayerData` |
| `QBCore.Functions.GetPlayerByCitizenId(citizenid)` | Re-resolve a known key (online only) |
| `QBCore.Functions.HasPermission(src, perm)` | **False-positive control** — distinguishes admin actions from anomalies |
| `QBCore.Functions.GetPermission(src)` | Authority context on incidents |
| `QBCore.Functions.GetPlayersInBucket(bucket)` | Routing-bucket awareness |
| `QBCore.Functions.GetIdentifier(src, 'license')` | **Investigation-time only**, never in telemetry |

`QBCore.Functions.HasPermission` deserves emphasis. The charter's
`MOVEMENT-DETECTION-ENGINEER` section requires accounting for admin actions as a
legitimate cause of teleport-like movement. Permission level is exactly that context, it
is server-side, and it is cheap. Movement detection consumes it from day one rather than
retrofitting it after the first false positive.

**Never used by this platform:** `QBCore.Functions.Kick`, `AddPermission`,
`RemovePermission`, `SetPlayerBucket`, `SpawnVehicle`, `CreateVehicle`. The first is
enforcement; the rest mutate game state. An observatory does neither. A guard script
fails the build if they appear outside `lab/`.

---

## 6. Prerequisite experiments (Tier B — owner's PC)

| ID | Question | Blocks |
| --- | --- | --- |
| `EXP-004` | What `qb-core` version is installed? Is the `exports['qb-core']:GetPlayer` path available? | Framework enrichment |
| `EXP-005` | Do the §4.1 weaknesses exist in the live `qb-core` source, or were they fixed since the docs were written? | Event-audit detector contracts |
| `EXP-006` | Which resources are installed (inventory, banking, garages)? Which register client-triggerable economy events? | Economy detector scope |
| `EXP-007` | Is `metadata.isdead` reliably set server-side at time of death? | Combat plausibility ("dead players shooting") |

None of these can be answered from the build container, and none are guessed at in code.

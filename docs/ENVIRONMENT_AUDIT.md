# ENVIRONMENT AUDIT — FiveM Security Lab

**Task:** TASK 001 — Environment Discovery (Phase 0)
**Date:** 2026-09-18
**Owner:** vzjRR
**Repository:** `vzjRR/sec-new`
**Branch:** `claude/fivem-security-lab-init-kn5k0r`
**Status:** Discovery complete. No implementation performed. No files deleted or overwritten.

Evidence standard for this document follows `§21 SECURITY RESEARCH STANDARD`. Every
claim is tagged:

| Tag | Meaning |
| --- | --- |
| **FACT** | Confirmed by official Cfx.re documentation or by machine-readable Cfx.re data. |
| **OBSERVATION** | Directly measured in this environment; command and output recorded. |
| **HYPOTHESIS** | Plausible but **not** yet tested. May not become a detection rule (`§21`). |

---

## 1. Executive summary

This is a **true greenfield environment**. The repository has zero commits and zero
files. There is **no FiveM server, no FXServer runtime, no resources, no framework and
no database** present. Consequently there is nothing to integrate with, nothing to
preserve, and no risk of overwriting an unrelated project.

Three discovery results materially shape the architecture and are the reason this
document exists before any code:

1. **All game-state observation must be server-side, and the server-side surface is a
   specific, enumerable set.** 0 of 6,416 GTA natives are server-callable; 360 of 943
   Cfx natives are. Detector design is bounded by that list, not by what client-side
   anti-cheats typically do.
2. **Server-authoritative aim telemetry is available.** `GET_PLAYER_CAMERA_ROTATION`
   and `GET_PLAYER_FOCUS_POS` are server natives under OneSync. Aim analysis does
   **not** require a trusted client agent. This removes the weakest link that most
   aim-detection designs depend on.
3. **A live FXServer cannot boot in this container.** It requires a valid
   `sv_licenseKey`; the documented `sv_lan` bypass does **not** work on the current
   build (measured, §6.3). This forces a two-tier test strategy and, in turn, forces
   detector logic to be pure, native-free Lua so it is testable off-server (§9).

Recommended next step: **TASK 002 — Architecture** (§10), then a scoped Phase 1.

---

## 2. Operating system and host

**OBSERVATION** — `uname -a`, `/etc/os-release`, `nproc`, `free -h`, `df -h`

| Property | Value |
| --- | --- |
| Distribution | Ubuntu 24.04.4 LTS (Noble Numbat) |
| Kernel | `6.18.44-fc-v33`, `x86_64` |
| CPU | 4 vCPU |
| Memory | 15 GiB total, ~14 GiB free |
| Writable disk | 252 G volume, ~30 G available |
| User | `root` (uid 0), passwordless `sudo`, `apt` functional |
| Shell | bash |

**OBSERVATION** — This is an **ephemeral remote container** (Claude Code on the web).
The repository was cloned fresh at container start and the container is reclaimed after
inactivity. Anything not committed and pushed is lost.

**Consequence:** the container is a valid **build/test** environment. It is **not** the
project's "private local FiveM laboratory" required by `§1`. That laboratory is the
owner's own machine, which holds the license key and a GTA V client. This split is
load-bearing and is formalised in §9.

---

## 3. Repository state

**OBSERVATION** — `git status`, `git log`, `ls -la`, `git remote -v`

```
On branch claude/fivem-security-lab-init-kn5k0r
No commits yet
nothing to commit (create/copy files and use "git add" to track)

origin  https://github.com/vzjRR/sec-new (fetch)
origin  https://github.com/vzjRR/sec-new (push)
```

| Property | Value |
| --- | --- |
| Working tree | Empty except `.git/` |
| Commits | **None** |
| Tags / branches | None besides the checked-out branch |
| Build tooling | None (`no package.json`, no lockfile, no Makefile, no CI config) |
| Linters / formatters | None configured |
| Existing docs | None |

**Conflict assessment: none.** `§7` (do not assume; integrate rather than replace) and
the instruction "do not overwrite unrelated projects" are satisfied trivially — there is
nothing else here. Every architectural choice is open, and every one must therefore be
justified and documented rather than inherited.

---

## 4. Development toolchain

**OBSERVATION** — `command -v` probe across 40 tools, plus `--version` calls.

### 4.1 Present

| Tool | Version / path |
| --- | --- |
| node | v22.22.2 (`/opt/node22/bin/node`) |
| npm | 10.9.7 |
| pnpm, yarn, bun | present |
| python3 | 3.11.15 |
| go | `/usr/local/go/bin/go` |
| rustc, cargo | `/root/.cargo/bin/` |
| java | `/usr/bin/java` |
| gcc, g++, make, cmake | present |
| git | 2.43.0 |
| curl, wget, jq | present |
| psql | client only (PostgreSQL 16) |
| redis-cli | client only |
| docker | client 29.3.1 (**daemon not running**) |
| tmux, systemctl | present |

### 4.2 Absent

`luajit`, `luarocks`, `dotnet`, `mono`, `msbuild`, `sqlite3` (CLI), `mysql`/`mariadb`
(client), `mongod`, `docker-compose`, `screen`, `deno`.

### 4.3 Installed during discovery

**OBSERVATION** — `lua` was absent, which would have blocked all off-server testing of
FiveM's primary scripting language. Installed additively (nothing removed or replaced):

```
apt-get install -y lua5.4
# -> /usr/bin/lua5.4 : Lua 5.4.6  Copyright (C) 1994-2023 Lua.org, PUC-Rio
# -> /usr/bin/luac5.4 also provided
```

`luajit` remains available from `noble/universe` if ever needed (candidate
`2.1.0+git20231223.c525bcb+dfsg-1`), but see §9.1 — FiveM uses Lua 5.4, not LuaJIT, so
`lua5.4` is the correct match.

### 4.4 Node built-ins relevant to storage and testing

**OBSERVATION** —

```
node -e "require('node:sqlite')"
# -> AVAILABLE: DatabaseSync, StatementSync, constants, backup
#    (emits ExperimentalWarning)
node -e "require('node:test')"
# -> AVAILABLE
```

Both matter: they give a zero-dependency SQLite engine and a zero-dependency test
runner for off-server analysis tooling, with no third-party supply chain.

---

## 5. Services, ports and databases

**OBSERVATION** —

| Check | Result |
| --- | --- |
| Listening TCP/UDP ports | **None** (`ss -tulpn` empty) |
| Docker daemon | **Not running** — `/var/run/docker.sock` does not exist |
| PostgreSQL server | Not responding (`pg_isready` → no response); client + config dir only |
| Redis server | Not running |
| MySQL / MariaDB | Server and client both absent |
| MongoDB | Absent |

**Consequences:**

- Port `30120` (FXServer default) is free.
- **No containerised integration dependencies are possible here.** Any test that needs
  a database service must either run a database in-process or not run in this container.
  This reinforces the §8 storage decision.
- `§16 DATABASE` says do not choose a database blindly. There is no database to inherit,
  and no database *server* can run here. Proposed decision in §8.

---

## 6. FiveM environment

### 6.1 Existing FiveM installation

**OBSERVATION** — filesystem search to depth 4 for `FXServer*`, `fxserver*`, `citizen`,
`*.cfx*`, `server.cfg`, `fxmanifest.lua`:

```
(no results)
```

| Item | Present? |
| --- | --- |
| FXServer artifacts / runtime | **No** |
| `citizen/` directory | **No** |
| `server.cfg` | **No** |
| Any resource (`fxmanifest.lua`) | **No** |
| Framework (ESX, QBCore, qbx_core, vRP, ox_core) | **No** |
| Inventory system (ox_inventory, qb-inventory, …) | **No** |
| Existing anti-cheat / security resource | **No** |
| Existing UI / dashboard / NUI code | **No** |
| Existing test environment | **No** |

Per `§7`, nothing about framework, inventory, target system, database, UI framework,
resource naming or server architecture is being assumed — because none exists. All of it
must be treated as an open decision and, where the project is eventually packaged for
real server owners, as an **integration surface that must be detected at runtime rather
than assumed**.

### 6.2 FXServer artifact availability

**OBSERVATION** — Cfx.re endpoints are reachable through the environment's HTTPS proxy:

| Endpoint | Status |
| --- | --- |
| `https://docs.fivem.net/docs/` | 200 |
| `https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/` | 200 |
| `https://registry.npmjs.org/` | 200 |

**OBSERVATION** — Artifact `35945-0d8a2a6f78a9922445d8930305af82a7b1826980/fx.tar.xz`
downloaded successfully (70,604,764 bytes) and extracted to an Alpine rootfs plus
`run.sh`. Contents confirm:

- `alpine/opt/cfx-server/FXServer` (ELF, musl-linked, launched via
  `ld-musl-x86_64.so.1`)
- Scripting runtimes present: `libcitizen-scripting-lua.so`,
  `libcitizen-scripting-v8.so`, `libcitizen-scripting-mono-v2.so`
- Built-in system resources: `chat`, `monitor`, `webpack`, `yarn`

The artifact lives at `/home/user/.fxlab/` — **outside the repository**, deliberately
untracked, and lost when the container is reclaimed.

### 6.3 FXServer boot test — BLOCKED (measured)

This was the single most important unknown, so it was tested rather than assumed.

**OBSERVATION** — A minimal probe resource (`fxmanifest.lua` + `server.lua` printing
`IsDuplicityVersion`, convars, `GetGameTimer`, `GetNumPlayerIndices`, a KVP round-trip,
and registering handlers for `weaponDamageEvent` / `explosionEvent` / `entityCreating` /
`playerJoining`) plus a minimal `server.cfg` were created and the server was launched
five ways:

| Attempt | Result |
| --- | --- |
| `sv_lan true` inside `server.cfg` | `Error: This server does not have a license key specified.` |
| `+set sv_lan true` on command line | same error |
| `+set sv_lan 1` on command line | same error |
| `+setr sv_lan true` on command line | same error |
| `+set sv_lan true +set sv_licenseKey ""` | reaches `Authenticating server license key...` then `Could not authenticate server license key. Invalid key format specified.` |

In all cases the server did reach resource discovery —
`[resources] Scanning resources.` / `[resources] Found 4 resources.` — but **never
executed any resource script**. No `[PROBE]` line was ever emitted.

**Conclusion (FACT, measured):** on build **35945**, FXServer requires a valid
`sv_licenseKey` to start. Resource *manifest scanning* happens before the license gate;
resource *script execution* does not.

**Documentation discrepancy — recorded per `§20`/`§21`:** the official server-commands
reference states that `sv_lan [true|false]` "makes the server LAN-only. It will not
appear in the public server list and **license key checks are skipped**." That behaviour
was **not reproducible** on build 35945. Treat the documented bypass as **stale or
removed**. Do not build any workflow on it. This is an OBSERVATION that contradicts
documentation, not a defect to work around.

**Impact:** live FXServer boot, live telemetry, and all scenario tests requiring a game
client must run on the owner's private local lab. See §9.

---

## 7. Server-side observability surface (the real design constraint)

Everything in this section is **FACT**, derived from Cfx.re's own machine-readable
native metadata (`runtime.fivem.net/doc/natives.json`,
`runtime.fivem.net/doc/natives_cfx.json`) and the official events reference.

### 7.1 The hard boundary

| Set | Total | Server-callable (`apiset` = `server` or `shared`) |
| --- | --- | --- |
| GTA natives (`natives.json`) | 6,416 | **0** |
| Cfx natives (`natives_cfx.json`) | 943 | **360** |

**No GTA native can be called from the server.** Every server-side observation the
platform can make comes from those 360 Cfx natives plus the routed game events in §7.3.
This list *is* the detector design space. Any detector concept that needs data outside
it needs either a client-side component (untrusted) or a different signal.

### 7.2 Aim and camera — server-authoritative

The most consequential finding for `AIM-DETECTION-ENGINEER`:

| Native | Hash | apiset | Returns | Documented note |
| --- | --- | --- | --- | --- |
| `GET_PLAYER_CAMERA_ROTATION` | `0x433C765D` | server | `Vector3` | "Gets the current camera rotation for a specified player. This native is used server side when using OneSync." |
| `GET_PLAYER_FOCUS_POS` | `0x586F80FF` | server | `Vector3` | "Gets the focus position (i.e. the position of the active camera in the game world) of a player." |
| `IS_PLAYER_IN_FREE_CAM_MODE` | `0x1F14F2AC` | server | `bool` | — |
| `GET_PED_DESIRED_HEADING` | `0xC182F76E` | server | `float` | — |

Aim direction and camera world position are obtainable **without trusting the client**.
This is why `§4`'s "build the observatory first" is achievable for aim as well as for
combat, and it is the basis for treating client-reported aim data as unnecessary.

**HYPOTHESIS (must be measured on the local lab before any detector uses it):** the
update rate, precision, and smoothing of `GET_PLAYER_CAMERA_ROTATION` are unknown, as is
its behaviour in first vs. third person, in vehicles, and during cutscenes. Per `§21`,
this cannot become a detection rule until measured. This is the first experiment the lab
should run.

**Explicitly NOT available server-side:** ped accuracy, weapon-wheel selection
(`GET_SELECTED_PED_WEAPON`'s docs state the client-side HUD selection "is not available
to FXServer"), and any camera *interpolation* detail. Detectors must not assume them.

### 7.3 Combat and entity events (server-side, routed via OneSync)

**FACT** — from the official server-events reference:

| Event | Signature highlights | Cancellable |
| --- | --- | --- |
| `weaponDamageEvent` | `sender`, `weaponType`, `weaponDamage`, `damageType`, `damageFlags`, `damageTime`, `hitComponent`, `hitGlobalId`, `hitGlobalIds[]`, `willKill`, `silenced`, `overrideDefaultDamage`, `localPosX/Y/Z`, `isNetTargetPos`, `parentGlobalId`, `hasVehicleData`, `tyreIndex`, `suspensionIndex`, `actionResultId/Name`, `hasImpactDir`, `impactDirX/Y/Z` | **Yes** |
| `explosionEvent` | `sender`, `explosionType`, `posX/Y/Z`, `damageScale`, `cameraShake`, `isAudible`, `isInvisible`, `ownerNetId` | **Yes** (requires OneSync) |
| `startProjectileEvent` | `sender`, `weaponHash`, `projectileHash`, `ownerId`, `targetEntity`, `firePositionX/Y/Z`, `initialPositionX/Y/Z`, `effectGroup`, `commandFireSingleBullet` | — |
| `ptFxEvent` | `sender`, `effectHash`, `assetHash`, `entityNetId`, `posX/Y/Z`, `offsetX/Y/Z`, `rotX/Y/Z`, `scale`, `isOnEntity` | — |
| `removeAllWeaponsEvent` | `sender`, `pedId` | — |
| `vehicleComponentControlEvent`, `respawnPlayerPedEvent` | (documented separately) | — |
| `entityCreating` | `handle` | **Yes** — "can be canceled to instantly delete the entity" |
| `entityCreated`, `entityRemoved` | `handle` / `entity` | No |
| `playerConnecting` | `playerName`, `setKickReason`, `deferrals{defer,update,presentCard,done,handover}`, `source` | **Yes** |
| `playerJoining` | `source`, `oldID` (TempID → final NetID) | No |
| `playerDropped` | (documented separately) | No |
| `playerEnteredScope` / `playerLeftScope` | `{ for, player }` | No |
| `onPlayerBucketChange` / `onEntityBucketChange` | routing-bucket transitions | No |
| `onResourceStart` / `onResourceStarting` / `onResourceStop` / `onServerResourceStart` / `onServerResourceStop` / `onResourceListRefresh` | resource lifecycle | `onResourceStarting` yes |

`weaponDamageEvent` is the richest per-shot combat primitive available and it carries the
attacker (`sender`), the target set (`hitGlobalIds`), the body region (`hitComponent`),
the weapon, the claimed damage, and a lethality flag. It is the natural spine of combat
and aim telemetry.

**Note on `§10`/`§12` discipline:** `weaponDamageEvent`, `explosionEvent`,
`entityCreating` and `playerConnecting` are all *cancellable*. That makes it technically
trivial to turn a signal straight into enforcement. The project rules forbid this
(`§4`, `§10`: "A detector must never directly ban a player"; `§12`: high confidence ≠
ban). Phase 2 must **observe only** and must not call `CancelEvent()`.

**UNCERTAINTY recorded per `§20`:** several `weaponDamageEvent` fields are undocumented
(`f104`, `f112`, `f112_1`, `f120`, `f133`) and the clock base and units of `damageTime`
are unstated. `hitGlobalId` vs. `hitGlobalIds[]` semantics need confirmation. These must
be characterised empirically on the local lab before any measurement derived from them is
trusted.

### 7.4 Player, ped, entity and network state

**FACT** — server-callable, verified present in `natives_cfx.json` with
`apiset: server|shared`:

- **Position / motion:** `GET_ENTITY_COORDS`, `GET_ENTITY_VELOCITY`, `GET_ENTITY_SPEED`,
  `GET_ENTITY_ROTATION`, `GET_ENTITY_ROTATION_VELOCITY`, `GET_ENTITY_HEADING`
- **Health:** `GET_ENTITY_HEALTH`, `GET_ENTITY_MAX_HEALTH`, `GET_PED_MAX_HEALTH`,
  `GET_PED_ARMOUR`, `GET_PLAYER_MAX_ARMOUR`
- **Damage attribution:** `GET_PED_SOURCE_OF_DAMAGE`, `GET_PED_SOURCE_OF_DEATH`,
  `GET_PED_CAUSE_OF_DEATH` (docs: "used server side when using OneSync")
- **Weapon:** `GET_SELECTED_PED_WEAPON` (alias of `GET_CURRENT_PED_WEAPON`)
- **Ped state:** `IS_PED_IN_ANY_VEHICLE`, `IS_PED_IN_VEHICLE`, `IS_PED_RAGDOLL`,
  `IS_PED_A_PLAYER`, `IS_PED_STRAFING`, `IS_PED_HANDCUFFED`, `IS_PED_USING_ACTION_MODE`,
  `GET_PED_STEALTH_MOVEMENT`, `GET_PED_SCRIPT_TASK_COMMAND`, `GET_PED_SCRIPT_TASK_STAGE`,
  `GET_PED_SPECIFIC_TASK_TYPE`, `GET_PED_IN_VEHICLE_SEAT`
- **Entity provenance (valuable for entity abuse):** `GET_ENTITY_TYPE`,
  `GET_ENTITY_MODEL`, `GET_ENTITY_POPULATION_TYPE`, `GET_ENTITY_SCRIPT`,
  `GET_ENTITY_ATTACHED_TO`, `GET_ENTITY_COLLISION_DISABLED`, `GET_ENTITY_ROUTING_BUCKET`,
  `GET_ENTITY_ORPHAN_MODE`
- **Enumeration (required under OneSync Infinity):** `GET_ALL_PEDS`, `GET_ALL_VEHICLES`,
  `GET_ALL_OBJECTS`, `GET_PLAYERS`, `GET_NUM_PLAYER_INDICES`, `GET_PLAYER_FROM_INDEX`
- **Vehicle:** `GET_VEHICLE_PED_IS_IN`, `GET_VEHICLE_BODY_HEALTH`,
  `GET_VEHICLE_ENGINE_HEALTH`, `GET_VEHICLE_PETROL_TANK_HEALTH`,
  `GET_VEHICLE_STEERING_ANGLE`, `GET_VEHICLE_HANDBRAKE`, `GET_VEHICLE_TYPE`,
  `GET_VEHICLE_DOOR_LOCK_STATUS`, `GET_VEHICLE_NUMBER_PLATE_TEXT`,
  `GET_VEHICLE_LOCK_ON_TARGET`, `GET_VEHICLE_HOMING_LOCKON_STATE`, and the full
  appearance setter/getter family
- **Identity:** `GET_PLAYER_NAME`, `GET_PLAYER_IDENTIFIER`,
  `GET_NUM_PLAYER_IDENTIFIERS`, `GET_PLAYER_GUID`, `GET_PLAYER_TOKEN`,
  `GET_NUM_PLAYER_TOKENS` (docs: "Tokens can be used to enhance banning logic, however
  are specific to a server"), `GET_PLAYER_ENDPOINT`, `IS_PLAYER_ACE_ALLOWED`

### 7.5 Network quality — the false-positive lifeline

**FACT** —

| Native | apiset | Notes |
| --- | --- | --- |
| `GET_PLAYER_PING` | server | Docs point to `GET_PLAYER_PEER_STATISTICS` for detail |
| `GET_PLAYER_LAST_MSG` | server | Time since last message |
| `GET_PLAYER_PEER_STATISTICS` | server | ENet peer stats, enum below |

Documented `PeerStatistics` enum (`ENET_PACKET_LOSS_SCALE = 65536`):

```
PacketLoss = 0              -- scale by PACKET_LOSS_SCALE; updates once per 10s
PacketLossVariance = 1
PacketLossEpoch = 2         -- ms since last packet-loss update
RoundTripTime = 3           -- mean RTT
RoundTripTimeVariance = 4
LastRoundTripTime = 5       -- updated once per 5s
LastRoundTripTimeVariance = 6
PacketThrottleEpoch = 7
```

Docs state: "These statistics only update once every 10 seconds."

This is directly responsive to `§QA / FALSE-POSITIVE ENGINEER` and
`§FALSE_POSITIVE_POLICY`: poor ping and packet loss — the most common benign cause of
movement and combat anomalies — are **measurable server-side**. Network-conditioned
evidence is therefore possible from Phase 2 onward, not a later refinement. The 10-second
refresh is itself a constraint: peer statistics are *context* for an incident window,
not a per-shot value.

### 7.6 Built-in storage and structured logging

**FACT** —

| Native | apiset | Purpose |
| --- | --- | --- |
| `SET_RESOURCE_KVP`, `SET_RESOURCE_KVP_INT`, `SET_RESOURCE_KVP_FLOAT` | shared | Persistent key/value write |
| `GET_RESOURCE_KVP_STRING`, `GET_RESOURCE_KVP_INT`, `GET_RESOURCE_KVP_FLOAT` | shared | Read |
| `*_NO_SYNC` variants + `FLUSH_RESOURCE_KVP` | shared / server | Fast bulk writes; explicit durability flush |
| `START_FIND_KVP`, `FIND_KVP`, `END_FIND_KVP` | shared | Prefix scan |
| `DELETE_RESOURCE_KVP` | shared | Delete |
| `PRINT_STRUCTURED_TRACE` | server | Emits JSON on server **fd 3** as `script_structured_trace`; docs note it is "not generally useful outside of server monitoring utilities" — which is precisely this project's use case |

FXServer therefore ships a persistent KV store and a structured-trace channel. Neither
requires an external database. This directly informs §8.

### 7.7 Trust-boundary ConVars (defaults are permissive)

**FACT** — from the official server-commands reference. These are the platform's own
hardening switches, and several **default to the insecure setting**:

| ConVar | Default | Security meaning |
| --- | --- | --- |
| `sv_stateBagStrictMode` | **`false`** | When false, "the network owner can modify the state of entities they own **and the player state**". Clients can write their own player state bag. When `true`, only the server can. |
| `sv_entityLockdown` | **`inactive`** | `inactive` = "Clients can create any entity". `relaxed` = block client script-owned entities. `strict` = "No entities can be created by clients". `full` = GTAV Enhanced only. |
| `sv_filterRequestControl` | **`0` (off)** | Blocks `REQUEST_CONTROL_EVENT` routing. `1` = block for player-controlled entities settled beyond `sv_filterRequestControlSettleTimer` (default 30000 ms); `2` = all player-controlled; `3` = stricter still. |
| `sv_scriptHookAllowed` | `false` | Docs: enabling "makes the server vulnerable to security issues". Correct default. |
| `sv_enforceGameBuild` | — | Startup-only; pins client game build. |
| `sv_authMinTrust` | `1` (of 1–5) | How *unlikely* identity spoofing is. Default is the least trustworthy. |
| `sv_authMaxVariance` | `5` (of 1–5) | How likely the identifier is to change. Default is the most volatile. |
| `sv_endpointPrivacy` | — | Hides player IPs from public server reports. Privacy-relevant (`§9 TELEMETRY`, minimise PII). |
| `onesync` | — | `on` / `off` / `legacy`. **`on` is required** for server-side game-event routing and state awareness. |
| `onesync_enableInfinity` | `true` | Startup-only. |

**This is a finding, not trivia.** A meaningful share of "cheating" on a default-configured
FiveM server is simply *permitted by configuration*. `EVENT-SECURITY-ENGINEER` and
`ENTITY-SECURITY-ENGINEER` should treat these ConVars as the **first** trust-boundary
control — configuration hardening precedes detection, because detecting an abuse the
server is configured to allow is strictly worse than disallowing it.

A **server configuration audit detector** (reads these ConVars via `GET_CONVAR*` and
reports drift from a hardened baseline) is therefore the highest value-per-risk detector
available: it is pure server-side, has **zero false-positive risk against players**,
costs almost nothing, and needs no behavioural baseline. It is the recommended Phase 4
starting point (§10).

### 7.8 OneSync constraints

**FACT** — from the OneSync reference:

- OneSync Infinity culls entities and players outside a **hardcoded 424-unit focus
  zone**, so "all player iteration will have to happen server-side".
- "Most of the sync data is handled through player `31` … game events are handled through
  this player as well."
- OneSync is free up to 48 slots; beyond that requires a Cfx Portal subscription tier.
- `sv_maxClients` ≥ 32 requires `onesync on` or `legacy`; > 64 requires `onesync on`.

**Consequence:** the entire server-side event surface in §7.3 and the camera natives in
§7.2 **depend on `onesync on`**. The platform must detect this at startup and refuse to
claim coverage it cannot deliver (see §10, Phase 1 health check).

---

## 8. Storage decision (proposed, per `§16`)

There is no existing database (§5, §6.1) and no database server can run in this
container. `§16` requires the smallest reliable local solution, documented.

**Proposal — three tiers, each justified:**

| Tier | Mechanism | Holds | Why |
| --- | --- | --- | --- |
| Config & small counters | FXServer **KVP** (`SET_RESOURCE_KVP*`, `START_FIND_KVP`) | mode flags, detector versions, per-player rolling counters, baselines | Built in (§7.6); no dependency; survives restart; prefix-scannable |
| Telemetry & evidence | **Append-only JSONL** files on disk, one file per category per rotation window | raw normalized telemetry, incident timelines | Append-only suits a forensic record (`§FORENSICS`): cheap writes, naturally ordered, trivially replayable as test fixtures, and tamper-evident by being write-once |
| Offline analysis | **`node:sqlite`** reading the JSONL | queries, baselines, dashboards, regression comparison | Zero third-party dependency (§4.4); keeps analytical load entirely out of the game server's tick |

**Rationale:** this keeps the *hot path* (the server tick) to appends and KVP writes
only, satisfying `§15 PERFORMANCE BUDGET`, while putting all query cost in an offline
process. It introduces **no external service**, which is required given §5. JSONL files
double as the replay fixtures that make §9's container-side testing possible — the same
artifact serves forensics and regression testing.

**Deferred:** MySQL/MariaDB (the FiveM community norm, usually via `oxmysql`) is
**not** adopted now. If the project is later packaged for real servers, it should be
added behind a storage interface, detected at runtime rather than assumed (`§7`). That
interface boundary should exist from Phase 2 so this stays a configuration change rather
than a rewrite.

**Status:** proposal, pending TASK 002 review. Not implemented.

---

## 9. Test strategy forced by the environment

### 9.1 CfxLua vs. vanilla Lua 5.4 — measured

**FACT** — FiveM uses "a modified version of Lua 5.4 … called *CfxLua*", with Grit-engine
additions: relative path literals, vectors and quaternions, and compile-time Jenkins hash
literals (backticks).

**OBSERVATION** — behaviour of the installed vanilla `lua5.4` (5.4.6):

| Construct | Vanilla Lua 5.4 result |
| --- | --- |
| `` local m = `adder` `` (hash literal) | **Syntax error:** ``unexpected symbol near '`'`` |
| `type(vector3)` | `nil` — **not available** |
| Plain module `dofile` + assertions | **Works** (verified with a `mean()` unit test) |
| `luac5.4 -p file.lua` | **Works** — exit 0 on valid, exit 1 with line number on invalid |

**Conclusion:** vanilla Lua 5.4 can unit-test FiveM Lua **only** where the code avoids
CfxLua extensions. `luac5.4 -p` is a usable syntax gate for all `.lua` files regardless.

### 9.2 The resulting architectural rule

Combining §6.3 (no FXServer boot here) with §9.1 (pure Lua is testable here) yields the
central design constraint:

> **Detector and telemetry logic must be pure, native-free Lua that avoids CfxLua
> extensions, with all native and event access confined to thin adapter layers.**

This is not a style preference; it is the only way the project gets automated regression
coverage (`§14`, `§22`) in an environment that cannot start a game server. Every detector
becomes a pure function from normalized telemetry to a detection result — which is also
exactly what `§10 DETECTOR CONTRACT` describes, and what makes results explainable under
`§11`. The constraint and the requirement agree.

Adapters may freely use backticks, `vector3` and natives; they simply are not unit-tested
in this container. Keeping them thin keeps the untested surface small.

### 9.3 Two-tier test topology

| Tier | Where | Can run | Cannot run |
| --- | --- | --- | --- |
| **A — Container / CI** (this environment) | Ubuntu container | `luac5.4 -p` syntax gate; pure-Lua unit tests of detectors, statistics and correlation; telemetry schema validation; JSONL fixture replay ("golden" regression); `node:sqlite` analysis tests | Anything requiring FXServer, natives, events, or a game client |
| **B — Private local lab** (owner's machine, `§1`) | Owner's FiveM server + GTA V client + license key | Live resource load; real telemetry capture; scenario tests (`AIM-001`, …); performance measurement; false-positive scenarios needing a real client | — |

**The bridge between the tiers is the JSONL telemetry file.** Tier B captures real
telemetry; those captures are committed as fixtures; Tier A replays them forever as
regression tests. This is what makes `§22 KNOWLEDGE LOOP` mechanical rather than
aspirational, and it means a detector's behaviour on real recorded data can be re-verified
without a game client.

**Recommendation:** every claim made about a detector must state which tier verified it.
Per `§27`, no feature is reported as working on the strength of Tier A alone.

---

## 10. Risks, and the proposed plan

### 10.1 Risks

| # | Risk | Severity | Mitigation |
| --- | --- | --- | --- |
| R1 | **No FXServer boot in this container** (§6.3). Server-integration defects stay invisible here. | High | Enforce §9.2 so logic is Tier-A testable; keep adapters thin; require Tier-B verification before any "works" claim (`§27`). |
| R2 | **Ephemeral container.** Uncommitted work is lost. | High | Commit and push every meaningful increment; never treat `/home/user/.fxlab` as durable. |
| R3 | **Cancellable events invite premature enforcement** (§7.3). | High | Phase 2 observes only; no `CancelEvent()`. Keep detection and enforcement separate systems (`§10`, `§12`). |
| R4 | **`GET_PLAYER_CAMERA_ROTATION` characteristics unmeasured** (§7.2). Building an aim detector on it now would convert a hypothesis into a rule — forbidden by `§21`. | High | Make its measurement the **first** lab experiment. No aim detector until then. |
| R5 | **Undocumented `weaponDamageEvent` fields** (§7.3). | Medium | Characterise empirically; never derive a measurement from an unverified field. |
| R6 | **Stale documentation** — the `sv_lan` bypass does not work (§6.3). Other docs may be stale too. | Medium | Prefer measured behaviour over documentation; record every discrepancy in `knowledge/`. |
| R7 | **OneSync dependency** (§7.8). Without `onesync on` most telemetry silently does not exist. | Medium | Phase 1 health check must detect and report it loudly rather than degrade quietly. |
| R8 | **Permissive ConVar defaults** (§7.7). The lab may "detect" abuse the server was configured to permit. | Medium | Ship the configuration audit first; harden before detecting. |
| R9 | **PII in telemetry** — identifiers, IPs, tokens are all reachable (§7.4). | Medium | Minimise collection (`§9`); prefer stable opaque IDs; consider `sv_endpointPrivacy`; document retention. |
| R10 | **Lab simulator leaking into production** (`§8`). | Medium | LAB/PRODUCTION modes with simulators in a separately-loaded resource that PRODUCTION refuses to start. |
| R11 | **No database server available** (§5). | Low | §8 design needs none. |
| R12 | **Performance regression from telemetry volume** (`§15`). | Medium | Per-feature budgets; prefer event-driven over polling; measure on Tier B. |

### 10.2 Proposed implementation plan

Discovery is complete; nothing below is implemented yet.

**TASK 002 — Architecture (next).** Produce `docs/ARCHITECTURE.md` per `§24`, grounded in
§7's verified surface: components, data flow, trust boundaries, client/server boundary,
telemetry flow, detector flow, incident flow, LAB/PRODUCTION separation, assumptions, and
— importantly — the limitations §7.2/§7.3 impose. Alongside it: `SECURITY_MODEL.md`,
`TRUST_BOUNDARY.md`, `TELEMETRY_SCHEMA.md`, `DETECTION_MODEL.md`,
`TESTING_METHODOLOGY.md`, `FALSE_POSITIVE_POLICY.md`, `PERFORMANCE_BUDGET.md`,
`ROADMAP.md`, the 18 `agents/*.md` role charters, and `CLAUDE.md` per `§6`.

**Phase 1 — Foundation.** Repository structure; `CLAUDE.md`; configuration system;
LAB/PRODUCTION mode; `[vzjrr-security]/security-core` with a manifest, self-identification,
structured logging, a clean start/stop path, and a **health/status check that asserts
`onesync on` and reports the §7.7 ConVar posture**. Verification: Tier A syntax gate and
unit tests here; Tier B resource-load confirmation by the owner.

**Phase 2 — Telemetry.** Versioned schema per `§9`; `security-telemetry`; normalization;
player lifecycle (`playerConnecting` / `playerJoining` / `playerDropped` /
`playerEnteredScope` / `playerLeftScope`); combat from `weaponDamageEvent`; entity from
`entityCreating` / `entityCreated` / `entityRemoved`; movement sampled from
`GET_ENTITY_COORDS` / `GET_ENTITY_VELOCITY`; network context from
`GET_PLAYER_PEER_STATISTICS`. **Observation only — no cancellation, no enforcement.**
First deliverable is the `§26` end-to-end demonstration on a single event type before
coverage widens.

**Phase 3 — Forensics.** Timeline, evidence storage, incident model (`§12`), correlation
IDs, investigation API.

**Phase 4 — First detectors.** Recommended order, easiest-to-defend first:
1. **Server configuration audit** (§7.7) — no player false-positive risk at all.
2. **Event/entity rate anomalies** — server-authoritative counts, cheap, clear semantics.
3. **Movement plausibility** — needs the §7.4 samples plus §7.5 network context and the
   full legitimate-cause list from `MOVEMENT-DETECTION-ENGINEER`.
4. **Aim/combat** — **only after** R4's measurement experiment completes.

**Phases 5–8** proceed as specified in the master prompt.

**Immediate prerequisite experiments for the local lab (Tier B):**
- **EXP-001:** characterise `GET_PLAYER_CAMERA_ROTATION` — update rate, precision,
  first/third person, in-vehicle, cutscene behaviour. Blocks all aim work (R4).
- **EXP-002:** characterise `weaponDamageEvent` — `damageTime` clock base and units,
  `hitGlobalId` vs `hitGlobalIds[]`, behaviour on miss vs hit, and the unknown fields (R5).
- **EXP-003:** measure `GET_PLAYER_PEER_STATISTICS` refresh behaviour under induced
  latency and packet loss, to calibrate network-conditioned thresholds.

---

## 11. Reproducing this audit

```bash
# Host
uname -a; cat /etc/os-release; nproc; free -h; df -h /

# Repository
git status; git log --oneline; git remote -v; ls -la

# Toolchain
command -v node npm python3 lua5.4 docker psql redis-cli
node --version; lua5.4 -v
node -e "require('node:sqlite'); console.log('sqlite ok')"
node -e "require('node:test'); console.log('test ok')"

# Confirm no pre-existing FiveM install
find / -maxdepth 4 \( -iname "FXServer*" -o -iname "citizen" \
  -o -iname "server.cfg" -o -iname "fxmanifest.lua" \) 2>/dev/null

# Verified native surface (counts in §7.1)
curl -sL https://runtime.fivem.net/doc/natives.json      -o natives.json
curl -sL https://runtime.fivem.net/doc/natives_cfx.json  -o natives_cfx.json
# then count entries whose apiset is "server" or "shared"

# FXServer boot attempt (§6.3) — expect the license-key failure
curl -sL -o fx.tar.xz \
 https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/\
35945-0d8a2a6f78a9922445d8930305af82a7b1826980/fx.tar.xz
mkdir -p server && tar xf fx.tar.xz -C server
./server/run.sh +set sv_lan true +exec server.cfg   # -> license key error

# CfxLua vs vanilla Lua 5.4 (§9.1)
printf 'local m = `adder`\n'   > bt.lua && lua5.4 bt.lua   # syntax error
printf 'print(type(vector3))\n' > v3.lua && lua5.4 v3.lua  # nil
luac5.4 -p somefile.lua                                     # syntax gate
```

Cfx.re documentation pages consulted: server events reference; net game events reference;
resource manifest reference; state bags; OneSync; server commands (ConVars); Lua runtime;
Lua server functions; resource FAQ; the OneSync explosion-interception cookbook article.
Docs body text was retrieved via the site's own page-data endpoint
(`/_next/data/<buildId>/<path>.json`) because the pages render client-side.

---

## 12. TASK 001 report (`§27` format)

### Completed
Full Phase 0 / TASK 001 environment discovery: OS and host, repository state, toolchain,
services and databases, FiveM environment, FXServer boot feasibility (tested, not
assumed), the verified server-side native and event surface, trust-boundary ConVars,
OneSync constraints, CfxLua-vs-vanilla-Lua test compatibility (measured), a storage
proposal, a test topology, a risk register, and a proposed implementation plan.

### Files changed
- `docs/ENVIRONMENT_AUDIT.md` (new — this document)

Nothing was deleted or overwritten. The repository had no prior files.

### Tests
Discovery probes only; no project code exists to test yet.
- FXServer boot: **5 attempts, all failed** on the license-key gate (§6.3). Recorded as a
  measured blocker and a documentation discrepancy.
- Pure-Lua unit test under `lua5.4`: **passed**.
- `luac5.4 -p` syntax gate on valid and invalid input: **passed** (exit 0 / exit 1).
- `node:sqlite` and `node:test` availability: **confirmed**.
- Cfx.re endpoint reachability: **confirmed** (200).

### Results
The environment is greenfield with no integration constraints. Server-side observability
is richer than assumed — notably server-authoritative camera/aim data (§7.2) — but is
strictly bounded: 0 of 6,416 GTA natives and 360 of 943 Cfx natives are server-callable.
A live FXServer cannot run here, which forces the pure-Lua, adapter-isolated detector
design in §9.2 and the two-tier test topology in §9.3.

### Problems
1. FXServer will not boot without the owner's license key; the documented `sv_lan` bypass
   is not functional on build 35945 (§6.3). Live verification requires the owner's machine.
2. Docker daemon unavailable, so no containerised integration dependencies (§5).
3. `GET_PLAYER_CAMERA_ROTATION` behaviour and several `weaponDamageEvent` fields are
   uncharacterised; per `§21` these block aim/combat detector work until measured (R4, R5).
4. `lua5.4` had to be installed; it cannot execute CfxLua extensions (§9.1).

### Security considerations
- No enforcement capability was built, and none should be until `§12`'s incident model
  exists. The cancellable events in §7.3 make premature enforcement easy and are
  deliberately left untouched.
- Permissive platform defaults (`sv_stateBagStrictMode=false`,
  `sv_entityLockdown=inactive`, `sv_filterRequestControl=0`) mean configuration hardening
  should precede detection (§7.7).
- Telemetry can reach identifiers, IPs and tokens; collection must be minimised and
  documented (`§9`, R9).
- Nothing in this task produced adversarial tooling. The probe resource only read state
  and registered no-op handlers.

### Performance
No runtime code shipped, so no runtime cost. Measured discovery costs: FXServer artifact
70,604,764 bytes; natives metadata ~3.3 MB combined; disk remains ~30 G free. The §8
storage design deliberately keeps the server tick to appends and KVP writes, with query
cost moved offline.

### Next task
**TASK 002 — Security Architecture** (`docs/ARCHITECTURE.md` and the supporting documents
listed in §10.2), for review before any Phase 1 implementation. Per the master prompt,
implementation waits on architecture approval.

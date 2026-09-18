# TRUST BOUNDARY

**Status:** governs all detector and adapter design.
**Grounded in:** `ENVIRONMENT_AUDIT.md` §7 (verified native/event surface, ConVar defaults).

---

## 1. The one thing to internalise

> An attacker controls **what they claim**. They do not control **the fact that the
> server observed them claiming it, nor when**.

Everything below is a consequence of that sentence. Detectors that forget it end up
asking "does this value look wrong?" — a question the attacker gets to answer. Detectors
that remember it ask "is this *sequence* physically and statistically consistent?" — a
question the attacker cannot fully control, because it depends on server-side timing and
on data from other players.

---

## 2. Boundary map

```
┌──────────────────────────────────────────────┐
│  GAME CLIENT — adversary-controlled          │  TRUST: NONE
│  game memory · natives · injected code       │
└───────────────┬──────────────────────────────┘
                │  network
    ┌───────────┼─────────────────────────────────┐
    │           │                                 │
    ▼           ▼                                 ▼
 net events   sync state                     state bag writes
 (args:NONE)  (routed game events)           (NONE by default!)
    │           │                                 │
    ▼           ▼                                 ▼
┌──────────────────────────────────────────────┐
│  FXSERVER                                    │
│  ┌────────────────────────────────────────┐  │
│  │ routed game events   TRUST: LOW        │  │  payload = claim
│  │ (weaponDamageEvent, explosionEvent…)   │  │  sender/timing = observed
│  ├────────────────────────────────────────┤  │
│  │ server natives       TRUST: HIGH       │  │  server-computed
│  │ (coords, velocity, camera rotation,    │  │  but lag/interp-distorted
│  │  ping, peer stats, health, armour)     │  │
│  ├────────────────────────────────────────┤  │
│  │ QBCore PlayerData    TRUST: MEDIUM     │  │  server-side, but only as
│  │ (citizenid, money, job, metadata)      │  │  correct as its writers
│  ├────────────────────────────────────────┤  │
│  │ other resources      TRUST: ASSUMED    │  │  share our process
│  └────────────────────────────────────────┘  │
└───────────────┬──────────────────────────────┘
                ▼
┌──────────────────────────────────────────────┐
│  SECURITY LAB — our evidence store  HIGH     │  append-only, local
└──────────────────────────────────────────────┘
```

---

## 3. Per-boundary rules

### 3.1 Game client — trust NONE

Runs on the adversary's machine. There is **no client-side component** in this
architecture, by design (`ARCHITECTURE.md` §2 C1). A client agent would be the first
thing neutralised, and anything it reported would be a claim wearing a uniform.

### 3.2 Client-triggered net events — args trust NONE, `source` trust HIGH

Every `RegisterNetEvent` handler on the server is an attack surface.

| Element | Trust | Why |
| --- | --- | --- |
| `source` | **HIGH** | Assigned by the server, not supplied by the client |
| every argument | **NONE** | Arbitrary type, arity and value |
| call timing | **OBSERVED** | The server saw it happen when it happened |
| call frequency | **OBSERVED** | A rate is a server measurement, not a claim |

So the contract for any sensitive event is: legitimate callers · expected parameter types
and arity · expected frequency · expected caller state · required permission · valid
server-side consequence. QBCore's own documented events are catalogued against this
contract in `QBCORE_INTEGRATION.md` §4.

**Practical consequence:** arity and type violations are *high-signal and cheap*. A
legitimate client never sends the wrong number of arguments — the resource's own client
code decides that. A malformed call is not a false positive waiting to happen; it is
close to proof of tampering with *that resource's* client script.

### 3.3 State bags — trust NONE by default

`sv_stateBagStrictMode` **defaults to `false`**, which per the official documentation
means "the network owner can modify the state of entities they own and the player
state". Any resource that reads player state to make a gameplay decision is reading
something the player can write.

Recommendation: `setr sv_stateBagStrictMode true`, flagged as `POSTURE-003`.

### 3.4 Client-created entities — trust NONE by default

`sv_entityLockdown` **defaults to `inactive`** — "clients can create any entity". This is
the mechanism behind vehicle/ped/object spawn abuse. Flagged as `POSTURE-004`.

### 3.5 Routed game events — payload LOW, envelope OBSERVED

This is the subtlest and most important row. Take `weaponDamageEvent`:

| Element | Trust | Notes |
| --- | --- | --- |
| `sender` | **HIGH** | Documented as "the server-side player ID of the player that triggered the event" |
| arrival time | **OBSERVED** | Our own monotonic clock |
| `weaponDamage`, `willKill`, `hitComponent`, `localPos*` | **LOW** | Attacker-chosen |
| `hitGlobalIds` | **LOW** | Claimed targets — but the *targets themselves* are observable |
| `damageTime` | **LOW + UNKNOWN UNIT** | Undocumented clock base (EXP-002) |

The right use is **cross-referencing**: compare the claim against server-observed
geometry, the target's server-observed position, and the shooter's server-observed camera
rotation — all of which arrive as separate `observed` records sharing a
`correlation_id`.

A cheat can claim a hit it did not make. It cannot easily make the server's own view of
two players' positions agree with a fabricated line of fire, and it cannot control the
inter-arrival timing distribution of its own claims.

### 3.6 Server natives — trust HIGH, but not omniscient

`GET_ENTITY_COORDS`, `GET_ENTITY_VELOCITY`, `GET_PLAYER_CAMERA_ROTATION`,
`GET_PLAYER_PING`, `GET_PLAYER_PEER_STATISTICS`, `GET_ENTITY_HEALTH`, `GET_PED_ARMOUR`
are computed by the server from sync state. They are the strongest signals available.

They are still **not ground truth about the player's screen**:

- values are derived from client sync updates, so they lag
- OneSync Infinity culls beyond 424 units
- interpolation smooths motion
- peer statistics refresh only every 10 seconds

A detector must treat these as *the server's honest view*, not as physics.

### 3.7 QBCore `PlayerData` — trust MEDIUM

Server-side, therefore not directly client-writable — but only as correct as the
resources that write it. If a vulnerable resource credits money on a client's word, the
resulting `money.bank` is server-side **and wrong**.

So: use it as context and for economy *deltas*, and treat a suspicious delta as evidence
about **a resource's event contract**, not automatically as evidence about the player.

### 3.8 Other resources — trust ASSUMED

A malicious resource in the same process can lie to us and read our data. Out of scope,
stated so it is not mistaken for coverage.

---

## 4. Confidence rules that fall out of this

Enforced in `DETECTION_MODEL.md` and checked in tests:

1. A detection resting **only** on `claimed` measurements **may not exceed confidence
   0.5**. Raising it requires at least one `observed` corroboration.
2. A detection may **never** rest on a client-supplied value the server could have
   computed itself. If the server can measure it, measure it.
3. Rates, counts and inter-arrival timings of claims are `derived` from `observed`
   arrival times and may carry full confidence — the attacker does not control our clock.
4. Contract violations on net events (arity, type, impossible caller state) are
   high-confidence about **tampering with the calling resource**, and are reported as
   findings about that event, not as behavioural accusations.

---

## 5. What this architecture cannot see

Stated plainly so nobody mistakes the boundary for a wall:

- injected DLLs, modified game files, cheat loaders — **invisible by design**
- client-side visual cheats with no behavioural consequence (wallhack used passively,
  ESP, chams) — no server-observable effect, therefore no signal
- an attacker who restricts themselves to behaviour indistinguishable from a skilled
  player — inherent to behavioural detection, not a defect

The goal is defensible, explainable detection of abnormal behaviour with few false
positives — not perfect coverage.

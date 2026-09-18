# PERFORMANCE BUDGET

Charter §15: security must not damage the server. A resource that costs frames is a
resource the operator will remove — so performance is a security property.

---

## 1. Principles

1. **Events over polling.** Event cost scales with real activity; polling cost scales
   with player count regardless of activity.
2. **Lowest useful frequency.** Every interval is justified in `lib/config.lua`, bounded
   by a min and max, and validated at boot. A mistyped `0` cannot busy-loop the server.
3. **Bounded memory, always.** The telemetry ring buffer has a hard capacity and
   **counts drops**. A telemetry spike is what a mass-abuse incident looks like — the
   anti-cheat must not be what takes the server down during an attack.
4. **Hot path appends; analysis is offline.** No queries, no joins, no aggregation in the
   game process.
5. **Server-side validation over continuous collection.** Prefer one authoritative check
   to a high-frequency sampler.

## 2. Current declared budgets

Every figure below is a **design intent, not a measurement**. Nothing has run inside
FXServer yet (`ENVIRONMENT_AUDIT.md` §6.3), so the "measured" column is empty on
purpose rather than filled with guesses.

| Component | Trigger | Declared intent | Measured |
| --- | --- | --- | --- |
| `weaponDamageEvent` adapter | per damage claim | O(1), table build + validate | **pending Tier B** |
| `explosionEvent` adapter | per explosion | O(1) | pending |
| entity adapters | per entity create/remove | O(1) + 5 native reads | pending |
| player lifecycle | per join/drop/scope | O(1) | pending |
| movement poller | 1000 ms × players | ~7 native reads/player | pending |
| network poller | 10000 ms × players | ~7 native reads/player | pending |
| aim poller | 500 ms × players | ~5 native reads/player | pending |
| schema validation | per record | pure Lua, no allocation beyond the error list | pending |
| ring buffer | per record | O(1) push, O(n) drain | pending |
| JSONL sink | per flush (1000 ms) | buffered append | pending |
| posture audit | boot + 300000 ms | 8 ConVar reads | pending |

### Poll interval justifications

| Poller | Interval | Why that number |
| --- | --- | --- |
| movement | 1000 ms | Frequent enough to catch a teleport between samples; cheap enough per player. Min bound 100 ms because polling faster than sync updates arrive yields duplicate data. |
| network | 10000 ms | Peer statistics **only refresh every 10 s server-side** (audit §7.5). Faster polling burns CPU for identical values. Min bound 5000 ms. |
| aim | 500 ms | **Provisional placeholder** to gather data for EXP-001. The native's update rate is unmeasured, so this is not a tuned value and is documented as such. |
| player_state | 5000 ms | Health/armour/weapon/job change slowly relative to combat. |

## 3. The aim poller is the one to watch

At 500 ms × 64 players that is 128 sampling operations per second, each doing ~5 native
calls. It is the most expensive thing in the design and its interval is **not yet
justified by measurement**.

EXP-001 must answer: how often does `GET_PLAYER_CAMERA_ROTATION` actually change? If it
refreshes at, say, 100 ms, polling at 500 ms loses detail; if it refreshes at 1 s,
polling at 500 ms is pure waste. Either way the current value is provisional and should
not be treated as tuned.

## 4. Storage

| Stream | Per record | 64 players, 1 hour, rough order |
| --- | --- | --- |
| movement (1 s) | ~350 B | ~80 MB |
| aim (500 ms) | ~300 B | ~135 MB |
| network (10 s) | ~300 B | ~7 MB |
| combat | ~450 B | activity-dependent |

**This is too much for continuous production use**, and saying so now is the point of
writing it down. Mitigations, in order of preference:

1. LAB captures high-rate telemetry for experiments; PRODUCTION does not.
2. Movement and aim sampling are **detector-driven** — sample densely only for players
   with an open incident, sparsely otherwise.
3. Rotate and compress daily; retain raw telemetry briefly and evidence for longer.
4. Store derived windows rather than raw samples once baselines are established.

Mitigation 2 is the architecturally interesting one and belongs in Phase 4, once there
are incidents to drive it.

## 5. Measurement plan (Tier B)

- FiveM's built-in profiler (`profiler record` / `profiler view`) for per-resource tick
  cost.
- `GetGameTimer()` deltas around adapter bodies, recorded as `system` telemetry.
- Resource memory over a multi-hour session.
- Ring-buffer `dropped_n` as the saturation signal — a non-zero drop count means the
  sink cannot keep up.
- Baseline comparison: server tick with the resources stopped vs started.

## 6. Thresholds for backing out

If any of these is observed on the lab, the responsible component is reduced or removed:

- security resources contribute > 0.5 ms average per server tick
- resource memory grows without bound over 4 hours
- ring-buffer drops occur during normal play (not just synthetic spikes)
- measurable impact on client frame times (there should be none — no client component)

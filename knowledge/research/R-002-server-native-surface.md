# R-002 — The server-callable native surface is finite and enumerable

- **Date:** 2026-09-18
- **Role:** FIVEM-CORE-ENGINEER
- **Tag:** **FACT** (from Cfx.re machine-readable native metadata)

## Claim
| Set | Total | `apiset` = `server` or `shared` |
| --- | --- | --- |
| GTA natives (`natives.json`) | 6,416 | **0** |
| Cfx natives (`natives_cfx.json`) | 943 | **360** |

## Evidence
`https://runtime.fivem.net/doc/natives.json` and
`.../natives_cfx.json`, counting entries by `apiset`.

## Implication
**This list is the entire detector design space.** No GTA native can be called from the
server, so every server-side observation comes from those 360 Cfx natives plus the
routed game events. A detector concept needing anything outside it requires either a
client component (untrusted — forbidden by C1) or a different signal.

Corollary findings worth their own emphasis:

- `GET_PLAYER_CAMERA_ROTATION` (`0x433C765D`, server, `Vector3`) — documented "used
  server side when using OneSync". **Aim telemetry needs no trusted client agent.** See
  R-003.
- `GET_PLAYER_FOCUS_POS` (`0x586F80FF`) — camera world position, server-side.
- `GET_PLAYER_PEER_STATISTICS` — packet loss, RTT and their variances, server-side. This
  is the false-positive lifeline for every timing- and position-derived signal.
- `GET_SELECTED_PED_WEAPON` docs note the client-side HUD weapon selection is **not**
  available to FXServer — do not assume it is.
- **Not available server-side:** ped accuracy, and any camera interpolation detail.

## Confidence
High; derived from Cfx.re's own published metadata. Re-check on a build bump, since
natives gain server support over time.

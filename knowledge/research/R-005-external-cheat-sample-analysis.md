# R-005 — Static analysis of a FiveM external cheat sample

- **Date:** 2026-09-19
- **Role:** RED-TEAM / LAB-SIMULATION ENGINEER (analysis only — nothing was executed)
- **Tag:** **OBSERVATION** (static analysis performed here; commands and output recorded)

## Provenance

Sample supplied by the owner from a Discord CDN link, described as a FiveM cheat.
**Static analysis only — the binary was never executed.** It was downloaded to a
scratch directory, never marked executable, and deleted after analysis. It is **not**
committed to this repository.

| | |
| --- | --- |
| SHA-256 | `021f53c2328113f02db282d7bde017efcf807b1021173e497c06711a15d7f98f` |
| SHA-1 | `430ef7824759dc2295eb6cc5591bf2558c71e350` |
| MD5 | `8b923746242130bc39f9566cf8ab60dc` |
| Size | 1,425,408 bytes |
| Type | PE32+ x86-64 console executable, 7 sections, not packed (overall entropy 6.63) |
| Compiled | 2023-03-11 14:46:52 UTC (PE timestamp; trivially forgeable) |

## Claim

The sample is an **external overlay cheat** for FiveM: a separate process that reads and
writes the game's memory, draws its own DirectX overlay, and moves the mouse cursor. It
does **not** inject a DLL, install a driver, or contain a loader.

Targets `FiveM_bXXXX_GTAProcess.exe` for builds **b2372, b2545, b2612, b2699**, with a
per-build offset table (`[FiveM] [+] Patched offsets (bXXXX)`) and a `Fivem not found.`
failure path.

## Evidence

**Imports (172 across 7 DLLs).** The capability profile is unambiguous:

| Capability | Evidence |
| --- | --- |
| Cross-process memory access | `OpenProcess`, `ReadProcessMemory`, `WriteProcessMemory`, `VirtualProtectEx` |
| Target discovery | `CreateToolhelp32Snapshot`, `Process32First/Next`, `Module32First/Next` |
| Own overlay window | `D3D11CreateDeviceAndSwapChain`, `D3DCompile`, `DwmExtendFrameIntoClientArea`, `SetLayeredWindowAttributes`, `CreateWindowExA` |
| Input synthesis | `SetCursorPos`, `GetAsyncKeyState`, `GetKeyState`, `GetCursorPos` |
| Mild anti-analysis | `IsDebuggerPresent` |
| **Network** | **none** — no WinINet, WinHTTP, Winsock, or URLMon imports |
| **Persistence** | **none** — no registry, service, autorun or self-copy imports |

**Feature inventory**, from the configuration keys (the settings the menu serialises):

- **Aimbot** — `aimbot_enabled`, `aimbot_fov_size`, `aimbot_selected_bone`,
  `aimbot_smooth_enabled`, `aimbot_smooth_speed`, `keybinds_aimbot`
- **Player ESP** — box, bones/skeleton, health bar, armor bar, weapon label, distance,
  render range, player and admin counts
- **Vehicle ESP** — enabled, range, count
- **Noclip** — `general_noclip_enabled`, `general_noclip_speed`
- Supporting: ImGui (`imgui_impl_dx11`, `imgui_impl_win32`), a JSON config parser, an
  embedded font, a weapon-name table for the ESP labels

**No C2 or stealer indicators.** The only URLs are font licensing
(`scripts.sil.org/OFL`, the Montserrat font) and Microsoft manifest schemas. No browser
credential paths, no wallet paths, no Discord token paths. The `socket` / `connection` /
`token` strings resolve to C++ `<system_error>` messages and JSON parser errors, not
network code. The resource directory is empty.

## Implication — the part that matters for this project

Mapping each feature to whether it produces a **server-observable** signature:

| Feature | Mechanism | Server-observable? | Our detector |
| --- | --- | --- | --- |
| Player ESP | memory read → own overlay | **No. None whatsoever.** | — |
| Vehicle ESP | memory read → own overlay | **No.** | — |
| Aimbot | `SetCursorPos` moves the real cursor → the real camera moves | **Yes** — `GET_PLAYER_CAMERA_ROTATION` | `aim.*` (blocked on EXP-001) |
| Noclip | `WriteProcessMemory` to position/physics | **Yes** — `GET_ENTITY_COORDS` | `movement.plausibility` |

This **validates three existing design decisions** against a real sample rather than
against reasoning alone:

1. **`SECURITY_MODEL.md` §1 adversary A5 was correctly scoped out.** Roughly two thirds
   of this cheat's feature surface is ESP, and it produces *nothing* server-side. Our
   documented blind spot is real, and the honest thing remains to say so rather than
   imply coverage.
2. **C1 (no client-side component) costs us nothing here.** This is a separate process
   that never injects into the game. A client-side agent of ours would not have seen it
   either, so the blind spot is a property of the threat, not of our architecture.
3. **EXP-001 is the right priority.** The aimbot's entire server-visible footprint is
   camera movement, and we cannot reason about camera movement until
   `GET_PLAYER_CAMERA_ROTATION` is characterised.

### The single most important finding: `aimbot_smooth_speed`

The aimbot ships with **configurable smoothing**. That setting exists for one reason:
an instantaneous snap to target is obvious, so the cheat interpolates toward the target
to imitate human aim.

Two consequences for detector design:

- **The naive signal is the wrong one.** "Did the camera snap?" is defeated by a slider
  the user can already move. A detector built on snap magnitude would catch only the
  users who left smoothing off.
- **It supports the `STATISTICS_ENGINEER` hypothesis.** Smoothed aim is *generated*, and
  generated motion tends to be more self-consistent than human motion, which varies with
  fatigue, range and target difficulty. So the promising signal is **absence of variance
  across many engagements**, not peak performance in one. That remains a **HYPOTHESIS**
  (`knowledge/` R-003 rules), and EXP-001 plus real captures must test it before any
  threshold exists.
- **The adversary holds a dial.** Smoothing trades effectiveness for stealth. Any aim
  detector should expect a distribution of settings across users, not a single
  behaviour — and should expect its true-positive rate to decay as users turn the dial
  down (`SECURITY_MODEL.md` §6).

## Limits of this analysis

- **Static only.** Nothing was executed, so runtime behaviour is inferred from imports,
  strings and configuration keys.
- **Absence of network imports is not proof of absence of network behaviour.**
  `LoadLibraryA` and `GetProcAddress` are present, so APIs could be resolved at runtime.
  Static analysis cannot exclude this. It can only say there is no *static* evidence of
  C2, exfiltration or persistence — which is consistent with the sample being what it
  claims to be, and is not the same as a clean bill of health.
- **No offsets, signatures or implementation detail are recorded here**, deliberately.
  This entry exists to inform detection, not to document how to build the thing
  (`CLAUDE.md` §2, `SECURITY.md`).
- **Probably already stale.** It carries offsets for builds b2372–b2699 and was built in
  March 2023. Against a current client build it would most likely hit its
  `Fivem not found.` path.

## What this does and does not change

**Does not change:** any threshold, any detector, any confidence value. A sample is not
a measurement of our platform's ability to see it.

**Does change:** confidence in the roadmap. EXP-001 was already first in the queue on
reasoning; it is now first on evidence too.

**Follow-up:** when `AIM-001` is built as a lab scenario
(`agents/RED_TEAM_ENGINEER.md`), it should reproduce **smoothed** aim rather than
instant snapping, because that is what real users of this class of tool actually
generate. A simulator that only produces snaps would validate a detector against a
threat that barely exists.

# R-004 — FiveM resource scripts have no `require`; chunk returns are discarded

- **Date:** 2026-09-18
- **Role:** FIVEM-CORE-ENGINEER
- **Tag:** **OBSERVATION** (absence of documentation + runtime inspection)

## Claim
There is no documented `require` for FiveM resource scripts. Every file listed in
`server_scripts` is loaded as a plain chunk into one shared per-resource Lua state, and
**the chunk's return value is discarded**. A module written as
`local M = {} ... return M` is therefore **unreachable** when loaded as a
`server_script`.

## Evidence
- The official Lua runtime page documents the `.lua` extension, compile-time hash
  literals, vectors/quaternions and `exports`. It documents **no module system and no
  `require`**.
- The Lua server-functions reference lists the runtime-specific globals
  (`AddEventHandler`, `RegisterNetEvent`, `CreateThread`, `Citizen.*`, `GetPlayers`,
  `PerformHttpRequest`, vector/quat constructors, …). **`require` is not among them.**
- The resource manifest reference describes `server_script`/`client_script`/
  `shared_script` as files to be *loaded*, with no module semantics. `lua54` is
  documented and deprecated (Lua 5.4 is now always used); nothing enables a package
  searcher.
- `strings` on `libcitizen-scripting-lua.so` shows `require` and `package`, but those
  are symbols of the linked Lua standard library, not evidence that the package library
  is opened for resource scripts. The bundled scaffolding under
  `citizen/scripting/lua/` (`json.lua`, `MessagePack.lua`) uses `require` for its own
  loading by the runtime, which is a different environment from a resource script.

Even if `require` were present, `package.path` would not contain the resource directory,
and resource files are not guaranteed to be on disk in a form Lua's searcher can reach.

## Implication
1. **This was a live bug in this repository.** The adapters used `require 'lib.mode'`.
   That works under vanilla Lua 5.4 in CI and **would have failed at boot on a real
   server** — precisely the class of defect Tier A cannot see (C2).
2. Fix: every pure module publishes itself to a resource-scoped global
   (`SecLab = SecLab or {}; SecLab.schema = M`) **and** returns the table. FXServer uses
   the global; CI uses the return value. No environment check needed.
3. **`fxmanifest.lua` order became load-bearing**, so each adapter `assert`s its
   dependencies and fails loudly rather than mysteriously.
4. `tests/unit/test_module_loading.lua` now simulates the FXServer loading model
   (`loadfile` into a shared environment, return value discarded). It is the only Tier A
   test that verifies anything about the boot path — and it immediately caught a missing
   `fxmanifest.lua` for `security-forensics`.

## Wider lesson
Tier A can pass while the resource is unloadable. The mitigation is not "trust Tier A
less" but **to simulate the runtime's loading contract wherever it can be characterised
from documentation**. Verify with `EXP-009` on the lab.

## Confidence
High that `require` is not available to resource scripts. Medium on the mechanism
detail (whether the package library is opened at all) — hence `EXP-009`: attempt
`print(type(require), type(package))` from a server script on the lab and record the
result.

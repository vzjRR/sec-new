# R-001 — `sv_lan` does not bypass the FXServer license check

- **Date:** 2026-09-18
- **Role:** FIVEM-CORE-ENGINEER
- **Tag:** **OBSERVATION** (contradicts official documentation)

## Claim
On FXServer build **35945**, a valid `sv_licenseKey` is required to start the server.
Setting `sv_lan true` does **not** skip the license check, contrary to the official
server-commands reference.

## Evidence
The official documentation states:

> `sv_lan [true|false]` — A boolean variable (default `false`). When set to `true`, makes
> the server LAN-only. It will not appear in the public server list and **license key
> checks are skipped**.

Five launch variants were tested against artifact
`35945-0d8a2a6f78a9922445d8930305af82a7b1826980`:

| Attempt | Result |
| --- | --- |
| `sv_lan true` in `server.cfg` | `Error: This server does not have a license key specified.` |
| `+set sv_lan true` | same |
| `+set sv_lan 1` | same |
| `+setr sv_lan true` | same |
| `+set sv_lan true +set sv_licenseKey ""` | reaches `Authenticating server license key...` then `Could not authenticate server license key. Invalid key format specified.` |

In every case the server reached resource discovery (`[resources] Scanning resources.` /
`Found 4 resources.`) but **never executed a resource script** — no probe output was
emitted.

## Implication
1. Resource *manifest scanning* happens before the license gate; resource *script
   execution* does not.
2. **No CI or container environment can boot FXServer** without the owner's license key.
   This is the origin of constraint C2 and therefore of the pure-logic / thin-adapter
   architecture and the two-tier test topology.
3. Treat the documented bypass as stale or removed. Do not build any workflow on it.

## Confidence
High for build 35945. Would change if a future build restores the behaviour, or if an
undocumented flag exists. Re-test on a build bump.

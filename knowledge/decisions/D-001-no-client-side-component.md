# D-001 — No client-side component, ever

- **Date:** 2026-09-18
- **Role:** SECURITY-ARCHITECT
- **Status:** accepted

## Decision
The platform has **no client-side code**. All signals are server-observed.

## Context
Most FiveM anti-cheats ship a client resource that reports on the client's own
environment. R-002 establishes that the server-side surface is finite (360 natives) but
genuinely rich — including server-authoritative camera rotation.

## Rationale
1. **A client agent runs on the adversary's machine.** It is the first thing neutralised,
   and everything it reports is a claim wearing a uniform.
2. **Its absence is what makes every signal defensible.** An incident built only on
   server observations cannot be undermined by "the client module was tampered with".
3. **The strongest signal is available server-side anyway** — camera rotation (R-003).
4. **It removes a whole class of false positives**: client-side detectors fire on
   legitimate mods, overlays, capture software and driver quirks.

## Alternatives considered
| Option | Rejected because |
| --- | --- |
| Client integrity reporting | Trivially spoofed; produces false positives on benign software |
| Signed/obfuscated client module | Obscurity, not security; raises cost for the attacker only briefly |
| Hybrid, client-side as a hint only | A "hint" becomes load-bearing the moment someone raises a confidence weight with it |

## Consequences
**Accepted blind spots:** injected DLLs, modified game files, cheat loaders, and passive
visual cheats with no behavioural consequence (wallhack used passively, ESP). These are
documented in `SECURITY_MODEL.md` §1 as A5 and stated as out of scope rather than
silently uncovered.

**Gained:** every signal is defensible, the attack surface of our own code is small, and
there is nothing on the client to reverse-engineer.

## Revisiting
Only if Cfx.re ships an attested client-integrity mechanism the server can verify
independently. A self-reported client module does not qualify.

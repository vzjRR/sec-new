# SECURITY MODEL

Who the adversary is, what they can do, and what this platform can honestly claim.

---

## 1. Adversaries

| # | Adversary | Capability | Observable? |
| --- | --- | --- | --- |
| **A1** | Menu user | Off-the-shelf cheat menu. Spawns entities, gives weapons, teleports, god mode, triggers events | **Yes, strongly.** Produces loud, server-visible effects |
| **A2** | Event abuser | Reads resource client scripts, calls net events directly with crafted arguments | **Yes.** Contract violations are server-observed |
| **A3** | Aim assistance user | Client-side aim modification; otherwise plays normally | **Partly.** Server has camera rotation, but characterisation is pending (EXP-001) |
| **A4** | Economy exploiter | Abuses a vulnerable resource's server-side logic to gain money/items | **Yes, as a resource finding.** Deltas are server-side |
| **A5** | Passive visual cheat user | Wallhack/ESP used without behavioural change | **No.** No server-observable consequence — confirmed against a real sample (R-005), where ESP is ~2/3 of the feature surface and produces nothing server-side |
| **A6** | Careful adversary | Deliberately stays within plausible human performance | **Largely no.** Inherent to behavioural detection |
| **A7** | Malicious resource author | Ships a resource the operator installs | **No.** Shares our process; out of scope |
| **A8** | Host compromise | Owns the machine | **No.** Out of scope |

The platform is designed for **A1, A2 and A4 first** — they are loud, server-observable,
and account for most real disruption on a QBCore server. A3 is the original motivation
but is gated on measurement. A5–A8 are stated as out of scope so nobody mistakes silence
for coverage.

## 2. What this platform claims

1. It **observes** server-authoritative behaviour and produces normalized, versioned,
   privacy-conscious telemetry.
2. It produces **reconstructable evidence** — an incident can be replayed from its
   records.
3. It **explains** its conclusions, naming the trust basis of every measurement.
4. It **minimises false positives**, treating them as more costly than misses.
5. It **audits the server's own configuration**, which is often the actual vulnerability.

## 3. What it does not claim

1. It is **not** client integrity checking. Injected code and modified files are
   invisible by design.
2. It does **not** detect everything. A1/A2/A4 well, A3 eventually, A5/A6 largely not.
3. It does **not** enforce. No bans, no kicks, no event cancellation.
4. It is **not** a replacement for hardening. `POSTURE-001..008` come first: detecting an
   abuse the server is configured to permit is strictly worse than not permitting it.
5. Its **absence of alerts is not evidence of a clean server.**

## 4. Defence in depth, in order

```
1. CONFIGURATION       sv_stateBagStrictMode, sv_entityLockdown,
                       sv_filterRequestControl, sv_scriptHookAllowed, onesync
                       -> POSTURE-001..008. Cheapest, highest value, no FP risk.

2. SERVER AUTHORITY    never trust a client value the server can compute
                       -> event contracts, server-side economy calculation

3. OBSERVATION         normalized telemetry over the verified server surface

4. DETECTION           pure detectors over telemetry, explicit confidence

5. CORRELATION         multiple independent signals

6. EVIDENCE            reconstructable incidents

7. ENFORCEMENT         OUT OF SCOPE. A separate, future, human-gated system.
```

Layers 1 and 2 prevent. Layers 3–6 explain. Most projects start at 4 and skip 1, which
is why they generate accusations instead of evidence.

## 5. Kill chain, and where we intervene

```
obtain cheat ─▶ inject ─▶ connect ─▶ act in-game ─▶ effect on server
    (blind)     (blind)   (partial)   (OBSERVED)      (OBSERVED)
                          ^                ^              ^
                          |                |              |
                  sv_authMinTrust    telemetry +      economy /
                  identity quality   detectors        entity state
```

We intervene late in the chain, deliberately: late is where the server has authority and
where observations are trustworthy. Early-chain interception requires client-side
integrity checking, which C1 rules out.

## 6. Adversary adaptation

Attackers read anti-cheat code. This repository is readable and its thresholds are
configurable, so:

- **No security through obscurity.** Strength comes from signals being
  server-observed, not secret.
- **Configurable thresholds** are a feature: each server tunes to its own population.
- **Contract violations are hard to avoid** — calling a net event with the right arity,
  types, frequency *and* a plausible caller state is a much higher bar than calling it at
  all.
- **Timing distributions are hard to fake** — the attacker does not control our clock,
  and making a distribution look human across many engagements is harder than making one
  shot look human.
- **Expect adaptation.** A detector's true-positive rate decays. That is why the
  knowledge loop (charter §22) and regression fixtures matter more than any single rule.

## 7. Privacy

Telemetry deliberately excludes real names, `charinfo`, birthdates, phone numbers,
bank account numbers, IPs and platform identifiers — enforced by the schema validator,
which fails CI. `player_key` is `QB:<citizenid>`: stable, opaque, non-identifying.

Identifier resolution for an actual investigation is a **separate, access-controlled
lookup**, not a field on every record. Evidence is stored locally; nothing is shipped to
a third party, and there is no global ban list — which FiveM's own resource FAQ lists
among the things it wants to avoid.

# Security policy and project boundaries

## What this project is

A **defensive** security research platform for a private, authorised FiveM laboratory.
It observes server-authoritative behaviour and produces evidence. It performs **no
enforcement**: no bans, no kicks, no event cancellation.

## Authorised use

This is a controlled laboratory on infrastructure the owner controls. Testing may include
controlled abnormal-behaviour simulation, synthetic telemetry, test clients, deliberately
malformed but **locally generated** inputs, reproducible scenarios, detection validation
and false-positive testing.

## Never built here

- public cheat software or cheat loaders
- credential theft, malware, destructive tooling
- tooling aimed at servers other than this lab
- anything designed to bypass commercial or public anti-cheat systems
- persistence mechanisms, or evasion mechanisms intended for use outside the lab

When an adversarial behaviour must be studied, the project builds a **controlled
simulator that produces the relevant telemetry**, not a working cheat. The distinction is
purpose and blast radius: a simulator produces the *signal* a detector consumes and runs
only on a private lab server; a cheat produces an *advantage* and works anywhere.

Simulators live in `lab/`, are refused at runtime in PRODUCTION mode, and are not part of
a production deployment's resource set.

## Enforcement is deliberately absent

`weaponDamageEvent`, `explosionEvent`, `entityCreating` and `playerConnecting` are all
cancellable, and QBCore exposes `Kick`. Turning detection into enforcement is a one-line
change — so `scripts/check_no_enforcement.lua` runs in CI and fails the build on
`CancelEvent`, `DropPlayer`, `Kick`, `TriggerClientEvent`, `SetEntity*`,
`ExecuteCommand`, and permission mutators inside `resources/` and `detectors/`.

Adding enforcement requires: validating the incident model first, recording a decision in
`knowledge/decisions/`, and only then amending the guard. Editing the guard alone is not
an acceptable path.

## Privacy

Telemetry deliberately excludes real names, QBCore `charinfo` (`firstname`, `lastname`,
`birthdate`, `phone`, `account`), IP addresses and platform identifiers
(Steam/Discord/license). The schema validator **fails CI** if any of these appear.

`player_key` is `QB:<citizenid>` — stable, opaque, non-identifying. Resolving a key to a
real identifier for an investigation is a separate, access-controlled action, not a field
on every record.

Evidence is stored locally. Nothing is shipped to a third party, and there is no global
ban list — which FiveM's own resource FAQ lists among the things it wants to avoid,
because an unverifiable shared ban list harms players across many servers.

## Reporting a vulnerability in this project

This is a private research repository. If you find a flaw in the platform itself —
especially anything that would let it be used offensively, leak player data, or produce
false accusations — open an issue or contact the owner directly. Do not include live
player data in a report.

## Responsible use of findings

Findings about third-party resources (for example, a vulnerable net event in an installed
resource) should be reported to that resource's maintainer before any public disclosure.
The purpose of this project is to make servers more defensible, not to publish working
exploits.

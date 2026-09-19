# Experiment harness — runbook

**LAB only.** This is a measuring instrument. It reads state and records what it sees.
It never modifies game state, never touches a player, and performs no enforcement.

It exists because `CLAUDE.md` §5 forbids turning a hypothesis into a threshold. Seven of
the eight planned detectors are blocked on a measurement, and this is how those
measurements get taken.

---

## Install

Copy both resources into your server's resource folder (they must be **two** separate
resources — EXP-010 measures what happens *between* resources, so a single one could not
test it):

```
lab/experiments/security-lab-exp/
lab/experiments/security-lab-exp-peer/
```

In `server.cfg`:

```cfg
set onesync on
set security_mode "LAB"       # the harness REFUSES to start in PRODUCTION

ensure security-core
ensure security-telemetry
ensure security-forensics
ensure security-detectors

ensure security-lab-exp-peer  # must start before security-lab-exp
ensure security-lab-exp
```

The harness needs `security-core` (for the mode) and `security-telemetry` (for the JSON
encoder). If `security_mode` is anything other than `LAB` it refuses to start and says
so — including if the mode cannot be read at all, because it **fails closed**.

---

## What runs automatically

On start, with no player needed:

| EXP | Question | Unblocks |
| --- | --- | --- |
| **004** | Which `qb-core` is installed? Is `GetPlayer` exported? | QBCore enrichment |
| **005** | Do the documented `SetMetaData` weaknesses exist in the live source? | `events.contract` |
| **006** | Which resources register client-triggerable server events? | `events.contract`, economy |
| **008** | Can a resource append to files, and how? | the JSONL evidence sink |
| **009** | Are `require` / `package` available to resource scripts? | confirms R-004 |
| **010** | Does a table containing functions survive an `exports` call? | cross-resource design |

Results print to the console **and** are written to
`security-lab-exp/results/experiments.json`. EXP-006's full inventory goes to
`results/event-inventory.json` — that file is the deliverable the event contracts get
built from.

---

## What you have to run by hand

These need a connected player doing something specific. Run them **from the server
console** — they are console-only on purpose, so a connected player cannot drive the
harness.

```
exp001 <playerId> [durationMs] [intervalMs]
```
**Move the camera continuously for the whole run.** Measures how often
`GET_PLAYER_CAMERA_ROTATION` actually *changes*, which is the number that decides
whether the aim poller's 500 ms default is sensible. Defaults: 20 s at 50 ms.
**This is the one that unblocks all aim detection.**

```
exp002start
   ... go and shoot things: hits, misses, headshots, vehicles, silenced, explosives ...
exp002stop
```
Captures raw `weaponDamageEvent` payloads verbatim so the undocumented fields
(`f104`, `f112`, `f120`, `f133`) and `damageTime`'s clock base can be analysed against
real data. Bounded at 2000 payloads.

```
exp003 <playerId> [durationMs]
```
Measures how often peer statistics actually refresh. The docs say 10 s; worth
confirming, because the false-positive policy leans on `stale_ms` being meaningful.
Ideally run it while inducing packet loss. Default 40 s.

```
exp007 <playerId> [durationMs]
```
**Die at least twice during the run.** Measures the lag between the server seeing
health ≤ 0 and `metadata.isdead` being set. `combat.dead_shooter`'s `grace_ms` comes
from this, and guessing it would mean false accusations against players on bad
connections. Default 60 s.

```
expreport
```
Re-prints and re-writes results at any time.

---

## Then send the results back

If Claude Code is running **on this machine**, just run:

```bash
bash scripts/collect-lab-results.sh /path/to/your/server/resources
```

It finds the results, validates them with this project's own JSON decoder, imports them
into `lab/results/`, and prints which experiments concluded and which are still blocked.
A corrupt or truncated file is reported rather than imported.

Otherwise, commit or paste:

- `security-lab-exp/results/experiments.json`
- `security-lab-exp/results/event-inventory.json`

Those two files unblock `events.contract`, `combat.dead_shooter`, the aim work, and the
network-conditioned thresholds that every timing detector depends on.

---

## How to read the output

Three things are deliberate and worth knowing:

**"Inconclusive" is a real outcome, not a failure.** An experiment that could not run
must never read like one that found nothing. Every inconclusive result states *why* —
usually "the player did not move the camera" or "no death was observed". Re-run it.

**Sample counts travel with every measurement.** A latency figure from 3 samples is not
the same claim as one from 3000, and the output shows which it is. `R.stats` returns
nothing at all below its minimum rather than reporting a mean of one value.

**EXP-006's inventory is a floor, not a complete list.** It is a lexical scan of
resource source, so a handler registered under a computed name is reported as
`<dynamic>` rather than guessed at, and globbed or escrowed files are counted as
skipped. The finding says how much it could not resolve. Treating it as complete would
silently omit events from contract coverage.

---

## Safety

- Refuses to start outside `LAB` mode, and fails closed if the mode is unreadable.
- Console-only commands; a connected player cannot trigger anything.
- Read-only: no natives that mutate game state, no client events, no enforcement.
  `scripts/check_no_enforcement.lua` scans `lab/` too, so this is checked in CI rather
  than promised.
- All captures are bounded (2000 payloads) so a long run cannot exhaust memory.

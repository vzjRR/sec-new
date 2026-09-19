# Experiment results

Populated by `bash scripts/collect-lab-results.sh <path-to-server-resources>` from a
session running on the server machine (`docs/LOCAL_SESSION.md`).

**These files are evidence.** Commit them. Every detector threshold that gets set from
here on should be traceable to a result in this directory, and a threshold that is not
is a guess — which `CLAUDE.md` §5 forbids.

The collector validates before importing: a truncated or half-written file is reported
and **not** imported, because a corrupt file silently becoming "the evidence" is exactly
the failure this project keeps guarding against.

| File | Produced by | Contains |
| --- | --- | --- |
| `experiments.json` | harness boot + commands | Every EXP result, with its tag, finding or reason, and sample count |
| `event-inventory.json` | EXP-006 | Every net event registration found, with its sites. The input to `config/event-contracts.lua`. |
| `weapondamage-capture.json` | EXP-002 | Raw `weaponDamageEvent` payloads for offline analysis |

Empty for now: nothing has run on a server yet.

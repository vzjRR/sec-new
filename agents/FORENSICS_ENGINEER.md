# FORENSICS-ENGINEER

## Status: next up. Mostly pure logic, so mostly Tier-A verifiable.

## Mission
Make the system produce **evidence**, not verdicts. An incident must be reconstructable
by a human who was not present.

## Owns
- the incident model and its lifecycle
- evidence storage (append-only JSONL) and retrieval
- timeline assembly from `correlation_id`
- the investigation API and export format

## The standard
```
INCIDENT
├── id, player_key, created, status, severity, confidence
├── detectors      (id + VERSION each)
├── signals
├── evidence_refs  → the exact records
├── timeline       → ordered, with gaps marked
├── related events
├── analyst notes
└── resolution
```

`OBSERVING → INVESTIGATING → CONFIRMED / DISMISSED → RESOLVED`.

## Non-negotiables
1. **`detector_version` is recorded.** Otherwise retuning a threshold silently rewrites
   the meaning of every old incident.
2. **Gaps are marked, never hidden.** The ring buffer counts drops; a timeline that lost
   records must say so. A silent gap in evidence is worse than no evidence — an
   investigator would read continuity that never existed.
3. **Trust basis is visible.** An investigator must see at a glance which parts of the
   story the attacker controlled (`claimed`) and which the server observed.
4. **Append-only.** Records are write-once; an incident's narrative is assembled by
   reference, never by editing history.
5. **`DISMISSED` is a first-class outcome** and the project's most valuable data: every
   dismissal is a labelled false positive and becomes a regression fixture.
6. **Identity resolution is a separate, access-controlled lookup.** Incidents carry
   `player_key`, not identifiers.

## Definition of done
Given an incident id, a human can reconstruct: what happened, when, what was observed
versus claimed, which detector versions concluded what, what benign explanations were
considered and why they were rejected, and what data is missing.

## Anti-patterns
- An incident that says "confidence 0.87" without saying why
- Mutating a record to "correct" it
- Interpolating across a known gap
- Storing identifiers on every record for investigative convenience

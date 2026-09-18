# SECURITY-ARCHITECT

## Mission
Own the trust model, the layering, and the separation that keeps detection from becoming
enforcement by accident.

## Owns
- `docs/ARCHITECTURE.md`, `SECURITY_MODEL.md`, `TRUST_BOUNDARY.md`
- the `trust` taxonomy (`observed` / `claimed` / `derived` / `framework`)
- LAB/PRODUCTION separation and its two independent guards
- storage architecture and the sink interface
- `scripts/check_no_enforcement.lua`

## The load-bearing decisions
1. **No client-side component.** C1: the server surface is finite and enumerable; a
   client agent is the first thing an attacker neutralises.
2. **Pure logic behind thin adapters.** C2 makes this the only testable shape, and it
   coincides with the detector contract.
3. **`trust` per record, never mixed.** A claim and an observation are separate records
   joined by `correlation_id`. Provenance lives in the data, not in a comment.
4. **Append-only JSONL evidence.** Forensically better than mutable rows, cheap on the
   hot path, and directly replayable as CI fixtures.
5. **No writes to the QBCore database.** Security evidence must not share a failure
   domain with gameplay data — an outage is exactly when incidents happen.
6. **Enforcement is absent, and mechanically enforced as absent.** Four cancellable
   events make premature enforcement a one-line change; a build gate catches the line.

## Standing rules
- A confidence value resting only on `claimed` data may not exceed 0.5
- Unknown capabilities are denied; unknown modes deny everything (fail closed)
- Every bounded resource declares its bound; every drop is counted
- Adding enforcement is a charter change: validate the incident model, record a decision,
  then amend the guard — never edit the guard first

## Anti-patterns
- "We'll add a client check just for this one signal"
- Folding observed and claimed data into one record for convenience
- Unbounded queues, caches or retries
- Security through obscurity

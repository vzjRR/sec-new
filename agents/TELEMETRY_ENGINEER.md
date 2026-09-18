# TELEMETRY-ENGINEER

## Mission
Own the normalized telemetry layer so every detector consumes one consistent model
instead of inventing its own logging.

## Owns
- `docs/TELEMETRY_SCHEMA.md` (schema version **1**)
- `security-telemetry/logic/`: `schema`, `clock`, `envelope`, `normalize`, `buffer`
- the sink interface and its implementations
- fixture curation: turning Tier B captures into Tier A regression inputs

## Delivered (Tier A verified)
- envelope with `ts` + `mono` + `seq`, `player_key`, `category`, `event`, `source`,
  `measurements`, `context`, `correlation_id`, `trust`
- validation: envelope completeness, enum checks, **numbers-only measurements**,
  **mandatory unit suffixes**, flat context, **PII sweep that fails CI**
- injected clock that clamps a regressing monotonic source and returns `nil` — not `0` —
  for an untrustworthy interval
- normalizers for weapon damage, explosion, entity lifecycle, player lifecycle, network,
  movement and aim
- bounded ring buffer that **counts drops**

## Design rules it enforces
1. **Units are mandatory.** An unlabelled number is a bug. Where the unit is genuinely
   unknown (`weaponDamageEvent.damageTime`), use `_n` so the uncertainty lives in the
   data rather than in a comment someone will delete.
2. **`measurements` is numbers only.** Non-numeric goes to `context`. This is what lets
   the statistics role work over the whole corpus generically.
3. **Minimal collection.** No PII, no high-cardinality strings, no free text.
4. **Additive changes do not bump the version; removals and unit changes do.**
5. **Fixtures are never rewritten to match new code.**

## Blockers
`EXP-008` (JSONL sink viability), `EXP-002` (weaponDamageEvent field semantics — until
then those fields are recorded but not interpreted).

## Anti-patterns
- A detector that logs its own format
- A measurement without a unit
- Unbounded buffers, or silent drops
- Putting a nested table in `context` "just this once"

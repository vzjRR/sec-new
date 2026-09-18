# Fixtures — the bridge between the two test tiers

A fixture is a recorded input plus the outcome it is expected to produce. Tier B
captures reality on the owner's lab; a curated capture becomes a fixture here; Tier A
replays it forever (`docs/ARCHITECTURE.md` §2 C3).

This is what makes the knowledge loop mechanical rather than aspirational: a detector's
behaviour on real recorded data can be re-verified without a game client.

Run them with:

```bash
bash scripts/replay.sh          # also part of scripts/verify.sh
```

---

## The rules

### 1. A fixture is never rewritten to match new code

This is the whole point. Rewriting a fixture to make a test pass destroys the
regression signal it existed to provide, and does so silently.

The harness enforces it: `--write` refuses to overwrite an existing `expected` block.
If behaviour genuinely changed for a good reason, delete the fixture and create a new
one with a new name and a decision record — so the change is visible in the diff rather
than hidden in a rewrite.

### 2. Provenance is mandatory

A fixture with no provenance cannot be trusted, because nothing says what produced it.
The harness **rejects** a fixture whose `meta` block is missing any of:

| Field | Why |
| --- | --- |
| `id` | Stable name, used in reports |
| `kind` | Which runner replays it (`posture`, `telemetry`) |
| `origin` | `synthetic` or `capture` — see §3 |
| `captured` | ISO date |
| `tier` | `A` for synthetic, `B` for a real capture |
| `description` | What behaviour or condition this represents |
| `schema_version` | So a v1 fixture keeps working after the schema moves on |

### 3. `synthetic` and `capture` are not the same thing, and the label matters

- **`capture`** — recorded from a real FXServer. The only kind that proves anything
  about real behaviour. Requires Tier B.
- **`synthetic`** — constructed by hand. Proves the *logic* behaves as specified, not
  that reality looks like this.

Mislabelling a synthetic fixture as a capture would overstate the evidence, which is
the failure this project exists to avoid. The harness prints the counts separately so a
report cannot imply more coverage than exists.

**A `posture` fixture is legitimately synthetic**, and this is not a compromise: the
detector's input is a ConVar snapshot, which *is* configuration. There is no gameplay to
capture, so a hand-written snapshot is the real thing.

**Telemetry fixtures must be captures.** A hand-written `weaponDamageEvent` proves only
that we can imagine one. Those await Tier B — see `docs/TESTING_METHODOLOGY.md` §7.

### 4. The legitimate cases matter as much as the positive ones

A fixture expecting **no** detections is how false-positive regressions get caught
(`docs/FALSE_POSITIVE_POLICY.md`). `posture-hardened-server` exists for exactly that: a
correctly configured server must produce nothing, forever.

### 5. Comparison is on signal, severity and confidence — not prose

Explanation wording is expected to improve. Comparing it would make every fixture break
on an editorial change and train everyone to rewrite fixtures, which breaks rule 1.

---

## Format

One `fixture.json` per directory. Written with this project's own deterministic JSON
codec, so it is byte-stable and diffs cleanly.

```json
{
  "meta": { "id": "...", "kind": "posture", "origin": "synthetic",
            "captured": "2026-09-18", "tier": "A",
            "description": "...", "schema_version": 1 },
  "input": { "convars": { "onesync": "off" } },
  "expected": { "detections": [ { "signal": "POSTURE-001", "severity": "critical",
                                  "confidence": 1.0 } ] }
}
```

For `kind: "telemetry"`, `input` is `{ "records": [ ... ] }` — telemetry records as
written by the JSONL sink.

## Current inventory

| Fixture | Kind | Origin | Expects |
| --- | --- | --- | --- |
| `posture-default-server` | posture | synthetic | 8 detections, worst critical |
| `posture-hardened-server` | posture | synthetic | **no detections** |
| `posture-blind-server` | posture | synthetic | `PLATFORM-BLIND` plus findings |

**No telemetry fixtures yet.** That is the honest state: they require a live server.

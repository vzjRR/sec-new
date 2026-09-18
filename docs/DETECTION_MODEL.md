# DETECTION MODEL

**Status:** contract defined; **no behavioural detector implemented yet** — by design
(`ROADMAP.md`). Detection is disabled by default (`detectors.enabled = false`).

---

## 1. The detector contract

```lua
-- PURE. No natives, no I/O, no events, no enforcement.
detect(state, record, config) -> DetectionResult | nil
```

| Argument | What it is |
| --- | --- |
| `state` | The rolling `PlayerState` for this `player_key`: recent windows, counters, baselines |
| `record` | The new `TelemetryRecord` |
| `config` | Thresholds and windows, all bounded and documented |

Returning `nil` is the normal case. A detector that fires often is either misconfigured
or wrong.

### Why pure

Three reasons, in order of importance:

1. **It is the only thing that is testable.** FXServer cannot boot in CI
   (`ENVIRONMENT_AUDIT.md` §6.3), so impure detectors would never have regression
   coverage.
2. **It is explainable.** A pure function's output is fully determined by inputs we
   recorded, so an incident can always be reproduced from its evidence.
3. **It cannot enforce.** A function with no I/O cannot ban anyone. The separation of
   detection from enforcement stops being a policy and becomes a type constraint.

---

## 2. `DetectionResult`

```lua
{
  detector_id      = 'combat.dead_shooter',
  detector_version = 1,
  player_key       = 'QB:ABCD1234',
  ts               = 1758204000123,
  mono             = 154321,
  signal           = 'shot_while_dead',
  measurements     = { gap_ms = 420, shots_n = 3 },
  confidence       = 0.35,
  severity         = 'medium',
  evidence_refs    = { 'c_9f2a1b' },
  explanation      = 'Three weapon damage claims arrived 420ms after the server '
                  .. 'observed this ped as dead. Claims are client-supplied; the '
                  .. 'death was server-observed.',
  context          = { trust_basis = 'claimed+observed', weapon_hash = 453432689 },
}
```

### `explanation` is not optional

It must let a human answer *why* without reading the code, and it must name the trust
basis. This is the field that makes the difference between evidence and an accusation.
A result whose explanation reads "anomaly score 0.87" is not evidence of anything.

### `detector_version`

Bumped on any change to logic or thresholds. Incidents record it, so an old incident
can always be read in the terms of the detector that produced it. Without this, retuning
a threshold silently rewrites history.

---

## 3. Confidence

Confidence is **the probability that the signal is what the detector thinks it is** —
not a severity, not a score to be summed.

| Band | Meaning | Allowed action |
| --- | --- | --- |
| 0.0–0.3 | Weak. Common benign explanations remain | Record only |
| 0.3–0.5 | Notable. Worth a timeline | Open `OBSERVING` |
| 0.5–0.7 | Strong, corroborated by ≥1 `observed` signal | `INVESTIGATING` |
| 0.7–0.9 | Multiple independent signals agree | `INVESTIGATING`, notify an analyst |
| 0.9–1.0 | Physically impossible, or contract violation | `CONFIRMED` *as a signal* |

### Hard caps, enforced in tests

1. **Claimed-only ≤ 0.5.** A detection resting solely on attacker-chosen fields cannot
   exceed 0.5 (`TRUST_BOUNDARY.md` §4).
2. **Unmeasured-native ≤ 0.3.** Anything derived from a native whose behaviour is not
   yet characterised — today: `GET_PLAYER_CAMERA_ROTATION` (EXP-001) — is capped until
   the experiment completes. `HYPOTHESIS` may not masquerade as evidence.
3. **Network-unexplained only.** A detection must be suppressed, or its confidence
   reduced, when concurrent `network` telemetry offers a sufficient benign explanation
   (`FALSE_POSITIVE_POLICY.md`).
4. **CONFIRMED ≠ enforcement.** Even 1.0 produces an incident, never a sanction
   (charter §12).

---

## 4. What a detector must never do

| Anti-pattern | Why it is wrong |
| --- | --- |
| `accuracy > X ⇒ cheating` | A single metric with no context, no distribution, no baseline. This is the reasoning the project exists to replace. |
| Trusting a claimed field because it "looks impossible" | The attacker chose the value. An impossible *claim* proves tampering with the claim, not the mechanism you assumed. |
| Summing arbitrary scores | Unjustified arithmetic. A weight needs a stated basis (charter §11). |
| Ignoring admin actions | `HasPermission` is available and cheap. An admin teleport is not a cheat. |
| Ignoring the network | Ping and packet loss are server-measurable. Omitting them manufactures false positives. |
| Firing on a single sample | Polling has gaps. One anomalous sample is a sample, not a pattern. |
| Reading the clock | Detectors are pure; time arrives in the record. |

---

## 5. Correlation (Phase 5)

Independent signals combine into a `RiskAssessment`. Two rules:

1. **Independence must be argued.** Two detectors reading the same `weaponDamageEvent`
   fields are *not* independent, and combining them inflates confidence on one piece of
   evidence. Combination requires distinct provenance.
2. **The assessment must answer "why".** It carries the contributing detections, their
   provenance, and the reasoning — not just a total.

Weights are not invented. Each needs a documented statistical or engineering
justification in `knowledge/decisions/`.

---

## 6. Incident lifecycle

```
OBSERVING ──▶ INVESTIGATING ──▶ CONFIRMED
    │                │              │
    └────────────────┴──────▶ DISMISSED ──▶ RESOLVED
```

An incident carries id, `player_key`, created, status, severity, confidence, contributing
detectors **with versions**, signals, evidence refs, timeline, related events, analyst
notes, resolution.

`DISMISSED` is a first-class outcome and the most valuable one for the project: every
dismissal is a labelled false positive and should become a regression fixture
(`FALSE_POSITIVE_POLICY.md`).

---

## 7. Planned detectors, in shipping order

Order is by *defensibility*, not by how interesting the cheat is.

| # | Detector | Trust basis | FP risk | Blocked by |
| --- | --- | --- | --- | --- |
| 1 | `server.posture` — ConVar hardening audit | observed (config) | **none against players** | nothing — **implemented** |
| 2 | `events.contract` — net-event arity/type/frequency/state violations | observed envelope | very low | event contract inventory (EXP-006) |
| 3 | `entity.rate` — client entity creation rate and provenance | observed | low | — |
| 4 | `combat.dead_shooter` — damage claims after a server-observed death | claimed + observed | low | EXP-007 |
| 5 | `movement.plausibility` — impossible displacement, network-conditioned | observed | **medium** — needs the full legitimate-cause list | — |
| 6 | `combat.sequence` — inter-arrival timing distributions of damage claims | derived from observed | medium | EXP-002 |
| 7 | `aim.*` | observed (camera) | high until characterised | **EXP-001** |

Detector 1 ships first precisely because it makes findings about the **server** rather
than accusations about players.

Aim detection is last despite being the original motivation. The telemetry exists and is
server-authoritative; what does not yet exist is knowledge of how the camera natives
behave. Building an aim detector now would mean shipping a hypothesis as a rule, which
charter §21 forbids.

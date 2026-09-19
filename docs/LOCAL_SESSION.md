# Handoff: running this project locally, with server access

**You are reading this because the session moved from a remote container to a CLI on the
machine that runs FXServer.** That is a real capability change, and this note says what
to do with it.

Read [`CLAUDE.md`](../CLAUDE.md) first — it carries the constraints, conventions and
current state. This file only covers what is *different* when the server is reachable.

---

## 1. What changed

The remote container could not reach the server at all (verified: no route to 30120, no
FXServer process). Everything was therefore Tier A — pure logic, unit tests, fixtures.

Running locally, **Tier B is now available**:

| Now possible | Why it matters |
| --- | --- |
| Read `server.cfg`, `resources/`, installed resource **source** | EXP-005 and EXP-006 become things you verify, not infer |
| Read `security-lab-exp/results/*.json` directly | No copy-paste round trip |
| Start FXServer and capture its console | You can issue `exp001` / `exp003` / `expreport` yourself |
| Restart a resource and observe the effect | Real iteration on adapters, which Tier A cannot test at all |
| Confirm the resources actually **boot** | The Phase 1 exit criterion, still unmet |

**What is still impossible:** playing the game. EXP-001 (move the camera), EXP-002
(shoot things) and EXP-007 (die twice) need a human at the keyboard. You can start the
runs and read the results; a person has to be in-game while they happen.

---

## 2. Do these in order

### Step 1 — confirm the resources boot. This is the Phase 1 exit criterion.

Nothing in this repository has ever run inside FXServer. That is a consequence of the
license-key constraint, not an oversight — but it means **every adapter is unverified**.
Expect problems here and treat them as the most valuable findings available.

```cfg
set onesync on                 # required; without it the platform is structurally blind
set security_mode "LAB"

ensure security-core
ensure security-telemetry
ensure security-forensics
ensure security-detectors
```

Then in the console: `security:status`.

A clean boot should show the mode, uptime, whether the server is state-aware, and the
ConVar posture summary. **Record whatever actually happens**, including a failure — a
boot failure is a Tier B finding and belongs in `knowledge/research/`.

### Step 2 — run the experiments.

Follow [`../lab/experiments/README.md`](../lab/experiments/README.md). Six run at boot;
four are console commands needing a player.

Priority order, because they unblock different things:

| Order | EXP | Unblocks |
| --- | --- | --- |
| 1 | **008, 009, 010** | automatic at boot; settle the storage and cross-resource designs |
| 2 | **004, 005, 006** | automatic at boot; EXP-006 is the event-contract deliverable |
| 3 | **001** | **all aim detection** — the project's original motivation |
| 4 | **002** | derived combat measurements |
| 5 | **007** | `combat.dead_shooter`'s `grace_ms` |
| 6 | **003** | network-conditioned thresholds for every timing detector |

### Step 3 — collect and commit the results.

```bash
bash scripts/collect-lab-results.sh /path/to/your/server/resources
```

It copies the result files into `lab/results/`, validates them with this project's own
JSON decoder, and prints which experiments concluded and which are still blocked.

Commit them. They are evidence, and they are what every subsequent detector decision
rests on.

---

## 3. What to do with the results

Each concluded experiment should produce a `knowledge/research/` entry — tagged
**FACT**, **OBSERVATION** or **HYPOTHESIS** per `CLAUDE.md` §5 — and then unblock work:

| Result | Then |
| --- | --- |
| EXP-001 concludes | Remove `poll:camera_rotation` from `UNCHARACTERISED_SOURCES` in `security-forensics/logic/detection.lua`, set `poll.aim_ms` from the measured change rate, and write the `aim/` design spec. **Not before.** |
| EXP-002 concludes | Same for `damageTime`; decide whether it can be labelled `_ms` instead of `_n`. |
| EXP-006 concludes | Write `config/event-contracts.lua` from the real inventory and implement `events.contract`. |
| EXP-007 concludes | Set `grace_ms` from the measured lag and implement `combat.dead_shooter`. |
| EXP-008 concludes | If `io.open` append fails, swap the evidence backend — the injected-backend design means only `security-forensics/sinks/file.lua` changes. |
| EXP-003 concludes | Calibrate the network rung of `movement.plausibility`'s attribution ladder. |

**An inconclusive experiment is not a licence to guess.** `CLAUDE.md` §5 is explicit:
a hypothesis may not become a threshold. Re-run it instead.

---

## 4. Capture telemetry fixtures while you are there

`lab/fixtures/README.md` §3 requires a **`telemetry` fixture to be a real capture** — a
hand-written `weaponDamageEvent` proves only that we can imagine one. There are
currently none, which is the single biggest gap in the regression suite.

With the server running, capture:

- **normal play** — the baseline the legitimate suite needs
- **each legitimate scenario** from `docs/TESTING_METHODOLOGY.md` §6: high ping, packet
  loss, admin teleport, garage retrieval, respawn, bucket change, vehicle combat

Those become `expected: no detections` fixtures, and they are how false-positive
regressions get caught forever after. They matter more than any positive case.

---

## 5. The boundaries have not changed

Server access does not widen the charter:

- **No enforcement.** No bans, no kicks, no `CancelEvent`. `scripts/check_no_enforcement.lua`
  is a build gate, and adding enforcement is a charter change requiring a decision record.
- **No real cheats.** If an adversarial behaviour needs studying, build a controlled
  simulator that produces the telemetry — never a working cheat (`SECURITY.md`).
- **No PII.** `charinfo`, identifiers and IPs stay out of telemetry; the schema validator
  fails CI if they appear.
- **Lab only.** The experiment harness refuses to start outside `LAB` mode and fails
  closed if the mode cannot be read.

---

## 6. Tier A still has to pass

```bash
bash scripts/verify.sh
```

Needs `lua5.4` and `luac5.4`. On Windows that means WSL, or skip it locally and rely on
the remote session — but **do not merge Tier B changes without running it somewhere**.

And keep the distinction honest in every report: Tier A passing is not Tier B passing,
and now that Tier B exists, say which one verified what.

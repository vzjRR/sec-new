# FALSE POSITIVE POLICY

---

## 1. Position

A false positive is **more costly than a missed detection**.

A missed cheat annoys players. A false accusation drives away a legitimate player,
damages the server's reputation, and — because it is usually invisible to the operator —
teaches them to distrust the whole system. Once an operator distrusts the detector, every
true positive is discounted too. One bad ban costs more than ten missed ones.

So: **when in doubt, record and do not conclude.** The system is allowed to say "I
observed something I cannot explain". That is a useful output.

## 2. Benign causes that must be modelled

For every detector, the design spec must state how each relevant cause is handled.

### Network (server-measurable — no excuse for ignoring)
high ping · packet loss · RTT variance · jitter · a dropped-then-resumed connection.
Available via `GET_PLAYER_PING`, `GET_PLAYER_LAST_MSG`, `GET_PLAYER_PEER_STATISTICS`.
**Caveat:** peer statistics refresh only every 10 seconds, so they are window-level
context. The `stale_ms` measurement exists so a detector can tell "0% loss now" from
"0% loss measured 9 seconds ago".

### Legitimate authority
admin teleports · admin god mode · staff spectating · `QBCore.Functions.HasPermission`
and `GetPermission` make this checkable and cheap.

### Legitimate game and resource mechanics
teleport scripts (garages, apartments, interiors) · respawn · `qb-ambulancejob` revive ·
routing-bucket changes · vehicle physics (ramps, explosions, tow) · NPC combat ·
cutscenes · resource restart · reconnect · server restart.

### Client-side variance
frame-rate drops · controller vs mouse · sensitivity differences · alt-tab · loading
stalls.

### Genuine skill
The hardest case. A highly skilled player produces *some* of the same measurements as a
cheat. Skill is distinguishable statistically — by **consistency and variance**, not by
peak values. A human's performance varies with fatigue, engagement type and target
difficulty; an assisted one often does not vary enough. **Peak performance is not
evidence. Absence of variance might be.**

## 3. Rules

1. **Every detector ships with false-positive tests.** No exceptions, no "later".
2. **Every detector's spec lists the benign causes it handles and those it does not.**
   An unhandled cause is a documented limitation, not a silent risk.
3. **Network context is mandatory** for any timing- or position-derived signal.
4. **Suppression is recorded.** When a detection is suppressed by a benign explanation,
   record the suppression. Suppression counts are how tuning gets measured, and a
   detector that is suppressed 99% of the time is telling you something.
5. **Every dismissed incident becomes a fixture.** `DISMISSED` is a labelled
   false positive — the most valuable data the project generates. It goes into
   `knowledge/false-positives/` with a replayable capture.
6. **Retuning a threshold bumps `detector_version`.** Incidents record the version, so
   history stays readable.
7. **A detector whose false-positive rate is unknown is not shipped**, regardless of how
   good its true-positive rate looks.

## 4. Measuring it

On the lab, with the legitimate scenarios from `TESTING_METHODOLOGY.md` §6:

```
FP rate = detections on legitimate scenarios / legitimate scenario runs
```

Target: **zero** on the legitimate suite before a detector is enabled. Not "low" —
zero, on a suite that is honest about what it covers. Growing the suite is how the
target stays meaningful.

Population-level tracking once real telemetry exists: detections per player-hour,
distribution across players, and the shape of that distribution. A detector that fires
on 30% of the population is describing normal play, not cheating.

## 5. The escape hatch

Any detector can be disabled by config without a code change, and detection is
**disabled by default**. If a detector starts misbehaving on a live server, the operator
turns it off in seconds. That is deliberate: a security system nobody can switch off is
a security system that will be uninstalled.

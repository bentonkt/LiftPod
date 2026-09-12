# RIR from repetitions and rep-speed trajectories

Updated September 12, 2026. Implementation: `WorkoutSession.swift` and
`WorkoutModel.swift`. These changes improve signal handling and validation;
they do not establish measured RIR accuracy for AirPod-recorded dumbbell lifts.

## What the evidence supports

| Primary study | Finding relevant to LiftPod | Implementation implication |
| --- | --- | --- |
| [Jukic et al., 2024](https://pmc.ncbi.nlm.nih.gov/articles/PMC10901726/) | In 46 trained participants performing back squats, individual RIR–mean-velocity relationships predicted subsequent-session RIR better than general relationships. Individual mean errors were below two reps across the tested loads. | Learn within the person and exercise. Test on held-out sessions; a good fit to training reps is insufficient. |
| [Martínez-Rubio et al., 2025](https://pubmed.ncbi.nlm.nih.gov/40125884/) | In 28 participants, individualized bench-press models improved subsequent-session prediction, particularly at 5 RIR. Accuracy varied with exercise mode and proximity to failure. | Keep measurement modes separate and present an estimated range rather than exact certainty. |
| [González-Badillo et al., 2017](https://pubmed.ncbi.nlm.nih.gov/28192832/) | Bench-press velocity loss related to the proportion of possible repetitions completed across submaximal loads. | Retain the published rep-count/velocity-loss equation as a low-confidence cold-start prior. |
| [Jukic et al., 2023](https://pubmed.ncbi.nlm.nih.gov/36823322/) | General and individual velocity-loss/percentage-completed relationships transferred poorly to later back-squat sessions. | Do not treat a fixed percentage slowdown as a universal RIR threshold. |
| [Prediction of Percentage of Completed Repetitions, 2024](https://www.mdpi.com/2076-3417/14/11/4531) | In 29 trained men, percentage-completed prediction was inaccurate across repeated squat sets. Using the first set's fastest velocity also introduced bias as fatigue accumulated. | Rebuild the speed reference each set. Include current absolute speed as well as relative loss. |
| [Paulsen et al., 2025](https://pubmed.ncbi.nlm.nih.gov/40832580/) | Exercise, load, set number, and velocity-loss threshold affected perceived RIR at a given mean velocity. | Restrict calibration by exercise and similar load. Preserve user correction. |
| [Martínez-Rubio et al., 2024](https://pubmed.ncbi.nlm.nih.gov/38109899/) | Inter-repetition rest and large individual variation limited equivalence between velocity-loss thresholds and effort. | Longer inter-rep pauses reduce confidence and exclude a trajectory from personal calibration. |

These studies measure bar velocity under specified execution conditions. They do
not validate ear-mounted IMU speed or the trajectory-matching algorithm below.
Deliberately slow lifting, altered range of motion, mounting changes, and poor
technique can resemble fatigue. Consistent lifting intent and technique matter.

## Signal processing now used

- Accept at least three positive finite finalized speed readings, at least 60%
  coverage, two early reference readings, and a valid final reading. The recent
  five-rep window must contain at least three readings. Keep original rep indices
  when readings are missing.
- Match the latest metric revision. A newer unavailable result cannot resurrect
  an older available value. Reject mixed estimator versions, measurement kinds,
  or generic movement-learning epochs within a set.
- Reference the fastest of the first three valid-position readings. If it exceeds
  the second-fastest by over 25%, use the second-fastest to contain a startup spike.
- Fit the last five rep positions with a Theil–Sen line: median pairwise slope,
  then median projected speed at the final rep. This preserves sustained decline
  while limiting one extreme reading. The largest residual above 15% of baseline
  marks the window noisy.
- Compute speed loss from the fitted recent speed and the within-set baseline.
  Also compute slowdown rate in percentage points per rep. Noisy windows still
  receive a provisional estimate with wider uncertainty.
- Preserve inter-rep pauses. A pause over three seconds in the recent window
  prevents personal-model use for that estimate. It does not suppress rep-based
  load/rest advice.

The five-rep window, 25% spike rule, 15% residual rule, three-second pause boundary,
and coverage thresholds are engineering choices, not published physiological
constants. The robust fit can delay recognition of an abrupt real decline until
another rep supports it; the rep ceiling remains an independent stop cue.

Generic movement uses full-cycle mean speed, explicitly identified as
`generic-cycle-speed`. It is not relabeled as validated concentric bar speed.
Exercise-specific metrics retain their own measurement identity.

## Estimator

The cold-start prior remains:

```text
p = -0.00855 × loss² + 1.83311 × loss + 5.55281
RIR = completedReps × (100 / p - 1)
```

Loss is bounded to 0–75% for this equation and p to 5.55281–100%. The output is
bounded numerically and displayed as 4+ when appropriate. Its source is the 2017
50–70% 1RM bench-press relationship. Applying it to robust IMU speed is an
unvalidated adaptation, so its confidence remains low.

For personalization, reconstruct each earlier rep's RIR as:

```text
RIR at prefix = user-entered final RIR + final rep count - prefix rep count
```

Only user-entered 0–4 final RIR values train the model. Automatically accepted
values cannot teach the model its own guesses. Corrected rep counts discard
that set's speed profile. Consider up to 24 recent sets of the same exercise,
estimator and measurement mode, within 25% of current load (2.5 lb minimum
allowance). Prefix labels above 10 RIR are excluded.

Match the current trajectory against prior prefixes using four features:

```text
distance² = (difference in loss / 15)²
          + (log(prior recent speed / current recent speed) / 0.35)²
          + (difference in slowdown per rep / 5)²
          + (difference in completed reps / 6)²
```

Require loss within 20 percentage points, baseline-speed ratio 0.6–1.67, and
squared distance at most four. Take only the closest prefix from each previous
set, then up to six sets. At least two sets must match. Average their RIR labels
with weight `1 / (0.25 + distance²)`.

This is a bounded nearest-neighbor engineering model. It combines completed
repetitions, current speed, accumulated degradation, and degradation rate rather
than adding multiple independent penalties for the same fatigue. Its distance
scales need validation against real LiftPod outcomes.

## Confidence and live coaching

Two matching sets can produce a low-confidence personal estimate. Medium
confidence requires at least three distinct sessions and leave-one-session-out
validation. Every session must have predictions for at least 80% of its eligible
near-failure observations. Average errors within each set, then each session so
long sets cannot dominate. Mean absolute error must be at most two reps and no
worse than the population prior on those same observations. A failed complete
validation falls back to the prior; insufficient validation stays low confidence.
The app does not award high confidence from these subjective labels.

The displayed RIR band uses ±2 reps for provisional estimates, ±3 with noise or
long pauses, and at least ±1 (or held-out MAE if larger) for validated personal
estimates. These are heuristic uncertainty bands, not calibrated statistical
confidence intervals. Values at four or above retain the `4+` meaning.

Live coaching uses the same estimator as set review. It marks the effort target
reached when the whole estimated band is at or below the selected RIR and the
upper end is finite rather than `4+`. It signals approach when the band overlaps
the target neighborhood. Reaching the maximum prescribed reps independently
marks the rep target reached, even without speed. Fixed 12%/19.5% slowdown
thresholds no longer claim a universal effort target.

Estimation updates only when the speed profile, prescription or history changes;
features are cached within validation. Signal recovery suppresses speed coaching.
Missing speed still leaves the concrete rep-based load and rest fallback available.

## Validation completed and remaining

Regression tests cover synthetic sustained decline, startup and terminal spikes,
invalid numbers, missing final speeds, count mismatch, revised invalid metrics,
mixed learning epochs, same-session leakage, successful and inconsistent personal
labels, load/exercise/estimator isolation, pauses, legacy decoding, and target-RIR
coaching. These verify software behavior, not physiological accuracy.

Next real-data evaluation should use designated validation sets with actual
additional technically valid reps completed, record lifting intent and mounting,
and split by entire future sessions. Report raw uncapped RIR MAE/bias, error within
one and two reps, interval coverage, estimate availability, time to detect the
chosen target, and performance by exercise/load/rep count. Compare the prior,
absolute-speed-only, loss-only, and full trajectory models on identical held-out
examples. Keep a separate final test set when tuning the engineering constants.

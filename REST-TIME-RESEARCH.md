# Suggested rest-time research

## Adaptive product rule

LiftPod pre-fills repetitions in reserve (RIR) from finalized rep-speed change when the automatic estimator has enough valid data. The user can correct it during set review. The automatic or confirmed value feeds the advisory rest target beside the live between-set timer. The next complete rep always starts the next set immediately, even when the timer is below the suggestion.

LiftPod calculates three candidates and displays the longest one. It does not
add them together because automatic RIR and velocity loss describe much of the
same fatigue.

```text
RIR candidate = 90 seconds
              + 30 seconds × max(0, 3 − RIR)
              + 30 seconds when completed reps ≥ 12

velocity candidate:
  below 20% loss  -> no additional floor
  20% loss        -> 180 seconds
  20% to 40%      -> interpolate from 180 to 300 seconds
  40%+ loss       -> 300 seconds

performance candidate, after two comparable confirmed sets:
  estimated capacity = completed reps + RIR
  if capacity drops by at least 20%:
    next rest = actual preceding rest × (1 + observed drop)
  otherwise:
    do not change the recommendation

suggested rest = max(RIR candidate, velocity candidate, performance candidate)
                 rounded to 10 seconds and capped at 5 minutes
```

The RIR candidate alone produces this deliberately small baseline:

| Confirmed set | Suggested rest |
| --- | ---: |
| Any rep count at 3–4 RIR | 1:30 |
| 1–11 reps at 2 RIR | 2:00 |
| 1–11 reps at 1 RIR | 2:30 |
| 1–11 reps at 0 RIR | 3:00 |
| 12+ reps | Add 0:30 |

The 90-second floor comes from a 2024 systematic review and Bayesian meta-analysis: rest longer than 60 seconds showed a possible small hypertrophy benefit, while the analysis did not find appreciable additional hypertrophy differences beyond 90 seconds. This is a compact suggestion, not the rest duration that maximizes repetition performance.

The RIR steps follow controlled evidence that acute fatigue rises as sets approach failure. Refalo et al. found a 25% decrease in lifting velocity four minutes after failure training, compared with 13% at 1 RIR and 8% at 3 RIR. Pareja-Blanco et al. also found greater fatigue and slower recovery when sets reached failure, especially with high maximum repetition counts. The 12-repetition threshold reflects that directional evidence without pretending the literature supplies a continuous equation.

The velocity anchors combine two findings rather than claiming a published
continuous equation. Pareja-Blanco et al. found substantially more fatigue and
slower recovery after 40% rather than 20% within-set velocity loss. Janićijević
et al. found that three minutes could preserve bench-press performance farther
from failure, while five minutes was needed closer to failure. The linear
interpolation between those anchors is a transparent product heuristic.

The adaptive step follows Zhang et al. more directly. Their protocol began at
180 seconds and multiplied the current rest by the observed repetition decline
when repetitions fell by at least 20%. For example, a decline from 10 to 8 reps
changed 180 seconds to 216 seconds, rounded to 220. Their protocol retained the
longer rest when performance stabilized; it did not shorten rest after a good
set.

LiftPod compares `reps + RIR` rather than raw repetitions so two sets stopped at
different proximities to failure are more comparable. This is an engineering
adaptation, not a validated published formula. The comparison only runs for
consecutive sets in the same session with the same exercise and load. The
five-minute cap is also a product boundary. Exercise, load, conditioning,
accumulated sets, and the user's performance goal still matter.

## Primary evidence

- [Singer et al. (2024)](https://pmc.ncbi.nlm.nih.gov/articles/PMC11349676/), *Give It a Rest: A Systematic Review With Bayesian Meta-analysis on the Effect of Inter-set Rest Interval Duration on Muscle Hypertrophy*, included nine randomized studies. Results suggested a possible small benefit beyond 60 seconds and no appreciable detected difference beyond 90 seconds, with substantial heterogeneity. DOI 10.3389/fspor.2024.1429789.
- [Refalo et al. (2023)](https://pubmed.ncbi.nlm.nih.gov/36752989/), *Influence of Resistance Training Proximity-to-Failure, Determined by Repetitions-in-Reserve, on Neuromuscular Fatigue in Resistance-Trained Males and Females*, compared six bench-press sets at failure, 1 RIR, and 3 RIR. Acute velocity loss and negative perceptual responses increased nearer failure.
- [Pareja-Blanco et al. (2019)](https://pubmed.ncbi.nlm.nih.gov/30836680/), *Time Course of Recovery Following Resistance Exercise with Different Loading Magnitudes and Velocity Loss in the Set*, found greater fatigue and slower recovery after 40% rather than 20% velocity-loss protocols. DOI 10.3390/sports7030059.
- [Janićijević et al. (2024)](https://pubmed.ncbi.nlm.nih.gov/38369845/), *Optimizing Mechanical Performance in the Bench Press: The Combined Influence of Inter-set Rest Periods and Proximity to Failure*, found that five minutes was needed to best maintain bench-press mechanical performance close to failure, while three minutes could suffice farther from failure. This shows why LiftPod labels its value a suggestion rather than a recovered/ready threshold. DOI 10.1080/02640414.2024.2317644.
- [Zhang et al. (2026)](https://pmc.ncbi.nlm.nih.gov/articles/PMC12815620/), *Developing a Repetition-Based Inter-Set Rest Adjustment Method in Resistance Training*, tested an adjustable rest protocol beginning at three minutes and increasing rest proportionally when repetitions fell by at least 20% between sets. It produced more repetitions than a fixed three-minute protocol and remained more time-efficient than self-selected rest. DOI 10.1177/19417381251398823.

## Future validation

LiftPod now records the actual preceding rest with each confirmed set. Future
validation should test whether the recommendation predicts preservation of
estimated rep capacity on held-out sets, then personalize the 20% trigger and
the velocity-to-rest curve. Rest should only shorten after individual data show
that a shorter interval repeatedly preserves the target; the current research
does not validate an automatic shortening rule.

## Missing-effort fallback

If neither automatic nor confirmed RIR is available, suggest 120 seconds plus
30 seconds for 12 or more completed reps. This is a labeled rep-based heuristic;
it does not record an invented RIR. Valid velocity loss can still raise the rest
floor. Performance-drop adaptation requires actual RIR on both comparable sets.
The fallback is available both before confirmation and after confirmation without
RIR, including the set-review sheet.

# Suggested rest-time research

## Product rule

LiftPod shows an advisory rest target beside the live between-set timer after the user confirms both repetitions and repetitions in reserve (RIR). The next complete rep always starts the next set immediately, even when the timer is below the suggestion.

```text
suggested rest = 90 seconds
             + 30 seconds × max(0, 3 − RIR)
             + 30 seconds when completed reps ≥ 12
```

This produces a deliberately small set of recommendations:

| Confirmed set | Suggested rest |
| --- | ---: |
| Any rep count at 3–4 RIR | 1:30 |
| 1–11 reps at 2 RIR | 2:00 |
| 1–11 reps at 1 RIR | 2:30 |
| 1–11 reps at 0 RIR | 3:00 |
| 12+ reps | Add 0:30 |

The 90-second floor comes from a 2024 systematic review and Bayesian meta-analysis: rest longer than 60 seconds showed a possible small hypertrophy benefit, while the analysis did not find appreciable additional hypertrophy differences beyond 90 seconds. This is a compact suggestion, not the rest duration that maximizes repetition performance.

The RIR steps follow controlled evidence that acute fatigue rises as sets approach failure. Refalo et al. found a 25% decrease in lifting velocity four minutes after failure training, compared with 13% at 1 RIR and 8% at 3 RIR. Pareja-Blanco et al. also found greater fatigue and slower recovery when sets reached failure, especially with high maximum repetition counts. The 12-repetition threshold reflects that directional evidence without pretending the literature supplies a continuous equation.

The exact 30-second increments are a transparent product choice. There is no validated equation that converts only curl repetitions and subjective RIR into an individualized rest time. Exercise, load, training goal, conditioning, accumulated sets, and the performance standard all matter.

## Primary evidence

- [Singer et al. (2024)](https://pmc.ncbi.nlm.nih.gov/articles/PMC11349676/), *Give It a Rest: A Systematic Review With Bayesian Meta-analysis on the Effect of Inter-set Rest Interval Duration on Muscle Hypertrophy*, included nine randomized studies. Results suggested a possible small benefit beyond 60 seconds and no appreciable detected difference beyond 90 seconds, with substantial heterogeneity. DOI 10.3389/fspor.2024.1429789.
- [Refalo et al. (2023)](https://pubmed.ncbi.nlm.nih.gov/36752989/), *Influence of Resistance Training Proximity-to-Failure, Determined by Repetitions-in-Reserve, on Neuromuscular Fatigue in Resistance-Trained Males and Females*, compared six bench-press sets at failure, 1 RIR, and 3 RIR. Acute velocity loss and negative perceptual responses increased nearer failure.
- [Pareja-Blanco et al. (2020)](https://pubmed.ncbi.nlm.nih.gov/30036284/), *Time Course of Recovery From Resistance Exercise With Different Set Configurations*, found greater fatigue and slower neuromuscular recovery after failure protocols, especially when maximum repetition count was high. DOI 10.1519/JSC.0000000000002756.
- [Janićijević et al. (2024)](https://pubmed.ncbi.nlm.nih.gov/38369845/), *Optimizing Mechanical Performance in the Bench Press: The Combined Influence of Inter-set Rest Periods and Proximity to Failure*, found that five minutes was needed to best maintain bench-press mechanical performance close to failure, while three minutes could suffice farther from failure. This shows why LiftPod labels its value a suggestion rather than a recovered/ready threshold. DOI 10.1080/02640414.2024.2317644.
- [Zhang et al. (2026)](https://pmc.ncbi.nlm.nih.gov/articles/PMC12815620/), *Developing a Repetition-Based Inter-Set Rest Adjustment Method in Resistance Training*, tested an adjustable rest protocol beginning at three minutes and increasing rest when repetitions fell by at least 20% between sets. It produced more repetitions than a fixed three-minute protocol. LiftPod can adopt this observed-repetition adjustment later, after at least two comparable sets exist. DOI 10.1177/19417381251398823.

## Future validation

Record the recommendation, actual rest time, subsequent confirmed reps and RIR, exercise, load, and set number. A useful personalized model should predict whether the next set preserves the intended reps and RIR. Increase the recommendation when repeated comparable sets lose at least 20% of repetitions, following Zhang et al.; shorten it only after held-out data show that performance remains stable.

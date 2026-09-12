# Load prediction research

## Recommended next-set optimizer

The best-supported short-term design is a bounded, exercise-specific feedback
controller. Its objective is not to maximize the weight. It selects an available
weight and repetition target that are most likely to finish inside the user's
chosen rep range and target RIR, while avoiding an unnecessarily large load
change.

This distinction matters for dumbbells. Moving from 30 lb to 35 lb is a 16.7%
increase, much larger than the 2–5% adjustments commonly used in published
autoregulation protocols. When the ideal calculated load is unavailable, LiftPod
should search both weight and repetitions rather than blindly rounding to the
nearest dumbbell.

### Inputs LiftPod already has

- selected exercise and goal;
- current weight and available weight increment;
- target repetition range;
- completed repetitions;
- automatic or user-corrected RIR;
- first/fastest-rep speed and within-set velocity loss;
- set number, preceding rest, estimator version, and measurement validity;
- recent confirmed sets for the same user and exercise.

### Judge-ready MVP rule

Use the just-completed set as feedback for the next set of the same exercise:

1. If repetitions are inside the target range and RIR is within one repetition
   of the target, keep the load.
2. If the set is too easy, evaluate the next heavier available weight. Recommend
   it only when the capacity model predicts a rep target inside the chosen range;
   otherwise keep the load and move the rep target upward within the range.
3. If the set is too hard, evaluate the next lighter available weight. If the
   current weight can still reach the range after the recommended rest, keep it;
   otherwise reduce it.
4. If RIR or speed data are invalid, use repetitions alone and label the result
   low confidence. If the rep count was corrected, discard that set's velocity
   profile.
5. Never change the selected load automatically. Present one recommendation,
   its predicted reps/RIR, and the measured reason.

The directly studied RIR/RPE controller changed the next set by 2% for every
0.5 RPE outside the target zone, equivalent to approximately 4% per one-RIR
error because RPE = 10 − RIR. A missed prescribed repetition added another 4%
reduction. These percentages were used with barbell squat and bench press and
small plates, so LiftPod should use them as a desired-load signal before mapping
to actual dumbbells, not as a claim that the same percentages are physiologically
optimal for curls or lateral raises.

```text
RIR error = observed RIR − target RIR
desired load change = current load × 0.04 × RIR error
```

Only apply the RIR correction when the result lies outside the accepted target
zone. Cap an MVP recommendation to one available equipment step. This produces
a stable, easy-to-explain demo and prevents a noisy estimate from causing a large
change.

### Candidate search

For each available load near the current load, use the capacity equation below
to estimate repetitions to failure. Subtract target RIR to obtain the predicted
working repetitions:

```text
predicted working reps(load)
    = predicted reps to failure(load) − target RIR
```

Choose among `(load, rep target)` pairs in the selected repetition range. Rank
them in this order:

1. predicted RIR stays in the accepted target zone;
2. predicted repetitions stay inside the selected range;
3. smallest change from the current load;
4. predicted repetitions closest to the middle of the range;
5. lower load wins a tie when uncertainty is high.

This makes the output an optimization result rather than a generic progression
rule:

```text
OPTIMIZED NEXT SET
35 lb × 10 reps · target 2 RIR

Why: 30 lb finished at 12 reps with 4 RIR.
35 lb is the closest available load predicted to remain in your 8–12 range.
```

### How to use velocity

Within-set velocity loss should feed the automatic RIR estimate. The optimizer
should then use that RIR once. Adding a second adjustment for the same velocity
loss would double-count one fatigue signal.

First- or fastest-rep speed has a separate future role: estimating readiness at
the beginning of the day. Fit a personal, exercise-specific relationship between
load and fresh-rep speed only after collecting multiple loads across multiple
sessions with the same estimator, mounting geometry, range of motion, and intent
to move quickly. A fresh rep that is meaningfully slower or faster than that
personal expectation can shift the day's capacity estimate. Do not copy a fixed
metres-per-second threshold from barbell studies to AirPod-measured dumbbell
motion. Use the device's validated smallest detectable change and the user's own
residual error.

Set number and rest time should initially appear in the explanation and training
log rather than enter an invented universal fatigue equation. Once LiftPod has
enough transitions, fit a personal model from:

```text
previous set load, reps, RIR, velocity loss, rest duration
    -> next set first-rep speed, completed reps, and RIR
```

That model can predict whether keeping the load after the recommended rest is
likely to work. Until it beats the bounded controller on held-out sets, the
controller remains the production recommendation.

### Confidence

- **Low:** repetitions only, population capacity prior, or low-confidence
  automatic RIR.
- **Medium:** valid RIR plus at least three comparable confirmed sets for the
  same exercise.
- **High:** the personal model predicts held-out next sets within one equipment
  increment and one repetition, with calibrated error bounds.

Evaluate the exact recommendation rather than only an estimated capacity. Report
the percentage of next sets that land inside both the rep and RIR targets, the
percentage within one repetition, load error in equipment steps, systematic
overloading, abstention rate, and performance by exercise and set number.

## Product decision

LiftPod records user-confirmed weight, repetitions, and optional repetitions in reserve (RIR). A suggested load never changes the workout automatically. The user must choose it and can edit it before training.

There is no defensible universal rule such as “four fewer reps means add 5 lb.” Repetitions completed at a percentage of 1RM vary substantially between people and exercises. The first LiftPod model therefore uses a load-dependent population curve, then combines the user's own recent confirmed sets for the same exercise.

For each eligible confirmed set, convert pounds to kilograms and calculate:

```text
effective reps = completed reps + RIR

capacity = weight × (1 + (effective reps − 1)^0.85 /
                     (−2.55 + 4.58 × ln(weight)))
```

The equation is from Marzagão's public 2026 preprint and requires kilograms. LiftPod uses only sets at 0–4 RIR, 2–15 effective reps, and at least 4 kg (8.82 lb), where this equation is numerically suitable. Adding RIR to completed reps is a transparent product adaptation: the source dataset contains near-failure sets and did not validate arbitrary RIR-adjusted sets.

The app uses as many as eight recent eligible sets. It computes a recency- and RIR-weighted mean capacity for that exercise, numerically solves the same equation for the requested reps plus target RIR, and rounds to the equipment increment. Recent sets receive weight `0.85^position`; RIR receives weight `1 / (1 + 0.25 × RIR)` because subjective RIR is less accurate farther from failure. These weighting constants are engineering choices to validate with LiftPod data, not published physiological constants.

Confidence is deliberately simple:

- low with fewer than three eligible sets, or inconsistent history;
- medium with at least three sets and weighted mean absolute deviation no greater than 15%;
- high with at least five sets and weighted mean absolute deviation no greater than 8%.

For the original example, 30 lb × 12 at 2 RIR produces a model capacity of 58.22 lb. Solving for 8 reps at 2 RIR gives 35.60 lb, which rounds to 35 lb on 5 lb equipment. The result happens to match the earlier answer, but now it follows the weight-dependent public-data curve. It remains a low-confidence estimate with only one confirmed set.

“Capacity” is shown in the implementation rather than claiming a measured 1RM. The source study optimized internal consistency and did not compare its estimates with directly measured 1RMs.

## Evidence

- [Nuzzo et al. (2024)](https://pmc.ncbi.nlm.nih.gov/articles/PMC10933212/), *Maximal Number of Repetitions at Percentages of the One Repetition Maximum*, modeled 952 repetitions-to-failure tests from 7,289 people in 269 studies. Natural cubic splines fit the pooled relationship best, and the authors quantified large between-person variation. Exercise mattered: at 80% 1RM, the model estimated 13.1 repetitions for leg press and 8.8 for bench press. The evidence supports exercise- and person-specific prediction rather than one fixed rep table. DOI 10.1007/s40279-023-01937-7. The authors published [data and code on OSF](https://osf.io/s94gf/).
- [Marzagão (2026)](https://sportrxiv.org/index.php/server/preprint/view/768), *A Weight-Dependent Formula for Predicting One-Repetition Maximum*, analyzed 303,494 near-failure sets from 14,966 users across 388 exercises. Its weight-dependent formula reduced within-user inconsistency by 17–22% versus four classical equations across 183 sufficiently sampled exercises. The paper directly motivates accounting for absolute load in light isolation exercises. It is a public preprint, has no directly measured 1RM outcomes, and needs external validation. [arXiv copy](https://arxiv.org/abs/2603.17495).
- [Dohoney et al. (2002)](https://www.ufjf.br/faefid/files/2009/07/1rm-prediction.pdf), *Prediction of One Repetition Maximum Strength From a 4–6 RM and a 7–10 RM Submaximal Strength Test*, reported preacher-curl-specific equations in 34 untrained young men. The 4–6RM biceps equation had adjusted R² 0.78 and standard error 6.3%; the 7–10RM equation had adjusted R² 0.68 and standard error 7.6%. That narrow sample, machine exercise, large intercept, and maximum 10-rep range make it unsuitable as LiftPod's general dumbbell-curl equation, but it reinforces that exercise-specific estimates can differ.
- [Lovegrove et al. (2022)](https://pubmed.ncbi.nlm.nih.gov/36135029/), *Repetitions in Reserve Is a Reliable Tool for Prescribing Resistance Training Load*, tested repeated 1-RIR load selection. Reliability was high, but the load selected at a given rep target differed by exercise. PMID 36135029; DOI 10.1519/JSC.0000000000003952.
- [Mansfield et al. (2020)](https://pubmed.ncbi.nlm.nih.gov/32881842/), *Estimating Repetitions in Reserve for Resistance Exercise*, found that RIR estimates became more accurate closer to failure. This supports down-weighting high-RIR observations and refusing predictions far from failure. PMID 32881842; DOI 10.1519/JSC.0000000000003779.
- [Jukic et al. (2024)](https://pubmed.ncbi.nlm.nih.gov/38418370/), *Modeling the Repetitions-in-Reserve-Velocity Relationship: A Valid Method for Resistance Training Monitoring and Prescription, and Fatigue Management*, found acceptable subsequent-session accuracy for individualized RIR–velocity relationships in the back squat, while the general relationship was not acceptable. This supports fitting a per-user, per-exercise model when LiftPod's speed metric is validated. PMID 38418370; DOI 10.14814/phy2.15955.
- [Zourdos et al. (2016)](https://pubmed.ncbi.nlm.nih.gov/26049792/) found strong inverse relationships between movement velocity and RPE/RIR and introduced a practical resistance-training RIR scale. PMID 26049792; DOI 10.1519/JSC.0000000000001049.
- [Helms et al. (2018)](https://pmc.ncbi.nlm.nih.gov/articles/PMC5877330/) compared RIR/RPE-regulated and percentage-based squat and bench-press programs. In the RPE group, the next set changed by 2% for every 0.5 RPE outside the target range; missed repetitions produced additional reductions. This supports a bounded feedback controller, while the exercises, loads, and long rest periods limit direct transfer to dumbbell isolation work.
- [Refalo et al. (2024)](https://pubmed.ncbi.nlm.nih.gov/37967832/) found mean absolute RIR error of 0.65 repetitions when trained participants reported 1 or 3 RIR during 75% 1RM bench press sets. This supports using near-failure RIR as feedback, not treating it as exact or universal.
- [Hickmott et al. (2022)](https://pmc.ncbi.nlm.nih.gov/articles/PMC8762534/) found broadly similar strength improvements from subjective RIR- and objective velocity-based autoregulation and no universal superiority over standardized loading. This argues for choosing the simpler transparent controller and validating it against LiftPod outcomes.
- [Greig et al. (2023)](https://pmc.ncbi.nlm.nih.gov/articles/PMC10432349/) found that individualized load-velocity 1RM models tended to overestimate measured 1RM and that more complex models did not clearly improve accuracy. LiftPod should optimize the next observable set rather than present a precise predicted 1RM.
- [Jukic et al. (2023)](https://pubmed.ncbi.nlm.nih.gov/37130910/) compared velocity devices and found materially different reproducibility and sensitivity. Mean velocity was the more defensible metric for some devices. AirPod-specific measurement error must therefore determine when a velocity change is large enough to affect a recommendation.

A 2020 paper titled *Estimating Repetitions in Reserve in Four Commonly Used Resistance Exercises* (PMID 33337690) was retracted and is excluded.

## Validation plan

The present model is a better population prior, not a finished personalized predictor. Evaluate each prediction against the next user-confirmed load at the same exercise, rep target, and RIR. Report median absolute error in pounds, accuracy within one equipment increment, signed error to detect unsafe overprediction, calibration by confidence level, and results by exercise and training experience.

Once speed metrics are available, fit an individualized RIR–velocity relationship per exercise. Use that signal to adjust or replace subjective RIR only after repeated-session validation shows lower held-out error. Until then, the app keeps the estimate optional and requires confirmation.

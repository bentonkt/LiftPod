# Load prediction research

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

A 2020 paper titled *Estimating Repetitions in Reserve in Four Commonly Used Resistance Exercises* (PMID 33337690) was retracted and is excluded.

## Validation plan

The present model is a better population prior, not a finished personalized predictor. Evaluate each prediction against the next user-confirmed load at the same exercise, rep target, and RIR. Report median absolute error in pounds, accuracy within one equipment increment, signed error to detect unsafe overprediction, calibration by confidence level, and results by exercise and training experience.

Once speed metrics are available, fit an individualized RIR–velocity relationship per exercise. Use that signal to adjust or replace subjective RIR only after repeated-session validation shows lower held-out error. Until then, the app keeps the estimate optional and requires confirmation.

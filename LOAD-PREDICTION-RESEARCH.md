# Load prediction research

## Product decision

LiftPod records the user-confirmed weight, repetitions, and optional repetitions in reserve (RIR) for every set. It never infers the weight from rep count alone. A first-pass suggestion appears only when the most recent confirmed set for that exercise includes RIR, and the user must choose whether to use it.

The current transparent estimate is:

1. Estimated reps to failure = completed reps + RIR.
2. Estimated 1RM = weight × (1 + estimated reps to failure / 30).
3. Solve the same relationship for the next target's reps + RIR.
4. Round to the nearest 5 lb equipment increment.

Example: 30 lb × 12 at 2 RIR estimates a 44 lb 1RM. A target of 8 reps at 2 RIR gives 33 lb, rounded to 35 lb. This is a heuristic suggestion, not a claim that eight reps automatically means the user used 35 lb. The confirmed notebook remains the source of truth.

## Evidence

- [Lovegrove et al. (2022)](https://pubmed.ncbi.nlm.nih.gov/36135029/), *Repetitions in Reserve Is a Reliable Tool for Prescribing Resistance Training Load*, tested repeated 1-RIR load selection. Test-retest reliability was high. In bench press, mean loads at 1 RIR were 93.0%, 87.3%, and 79.6% of 1RM for 3, 5, and 8 repetitions; in deadlift they were 88.2%, 84.3%, and 79.2%. This directly supports the idea that a lower rep target at the same RIR generally maps to a higher load, while also showing exercise-specific differences. PMID 36135029; DOI 10.1519/JSC.0000000000003952.
- [Zourdos et al. (2016)](https://pubmed.ncbi.nlm.nih.gov/26049792/), *Novel Resistance Training-Specific Rating of Perceived Exertion Scale Measuring Repetitions in Reserve*, found strong inverse relationships between movement velocity and RPE/RIR in experienced and novice squatters and described RIR as a practical way to regulate daily load. PMID 26049792; DOI 10.1519/JSC.0000000000001049.
- [Mansfield et al. (2020)](https://pubmed.ncbi.nlm.nih.gov/32881842/), *Estimating Repetitions in Reserve for Resistance Exercise*, found that RIR estimates became more accurate closer to failure and that early-set estimates could underestimate actual RIR. This supports collecting RIR while treating it as uncertain input rather than ground truth. PMID 32881842; DOI 10.1519/JSC.0000000000003779.
- [Nuzzo et al. (2023)](https://link.springer.com/article/10.1007/s40279-023-01937-7), *Maximal Number of Repetitions at Percentages of the One Repetition Maximum*, pooled the reps–%1RM literature and found substantial variability, including differences by exercise. That argues against one universal rep table for curls, presses, and raises. DOI 10.1007/s40279-023-01937-7.
- [Marzagão (2026)](https://arxiv.org/abs/2603.17495), a public preprint using 303,494 near-failure sets from 14,966 users and 388 exercises, reported 17–22% lower within-user inconsistency than four classical 1RM equations with a weight-dependent formula. It is valuable product-direction evidence, especially for light isolation exercises, but it has no directly measured 1RM outcomes and is not yet a sufficient basis for silent automatic loading. arXiv:2603.17495.

One 2020 paper titled *Estimating Repetitions in Reserve in Four Commonly Used Resistance Exercises* was retracted and is excluded from the product rationale.

## Next model

After enough confirmed history exists per user and exercise, replace the generic equation with a conservative personalized model:

- fit each exercise independently;
- use only confirmed sets with RIR and known equipment increments;
- weight recent sets more heavily while retaining multiple sessions;
- estimate uncertainty and suppress suggestions when uncertainty is high;
- cap session-to-session changes and always require user confirmation;
- later incorporate the partner's validated speed metric, since velocity can improve proximity-to-failure estimates.

The evaluation dataset should compare predicted versus subsequently confirmed loads at the same target reps and RIR. Report median absolute error in pounds, within-one-increment accuracy, calibration by exercise, and performance across new versus experienced users.

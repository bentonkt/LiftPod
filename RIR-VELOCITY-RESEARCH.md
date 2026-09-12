# Automatic RIR from rep velocity

## Product decision

LiftPod estimates repetitions in reserve (RIR) only after a set closes and only when the speed pipeline produces trustworthy finalized mean lifting speeds for at least three detected reps, including the final rep. The estimate pre-fills the review screen, drives the suggested rest time immediately, and remains editable before the set enters workout history.

The current set's velocity loss is:

```text
baseline = fastest available mean lifting speed among the first 3 reps
velocity loss (%) = 100 × (1 − final rep speed / baseline)
```

At least 60% of the set's detected reps must have available speed results. Pending, unavailable, non-finite, and non-positive speeds are rejected. RIR is capped at 4 for downstream suggestions; the interface displays `4+` when the uncapped estimate is at least four.

## Cold start

Before LiftPod has a usable individual model, it applies the published 50–70% 1RM bench-press equation from González-Badillo et al. (2017):

```text
percent of possible repetitions completed
    = −0.00855 × velocityLoss² + 1.83311 × velocityLoss + 5.55281

estimated RIR
    = completedReps / (percentCompleted / 100) − completedReps
```

The equation reported R² = 0.964 and standard error 5.44 percentage points in that study. LiftPod bounds its input and output and labels the result **Low confidence**. It is a starting heuristic, not a validated dumbbell-curl equation: the study used mean propulsive bar velocity in male bench press participants, while LiftPod measures AirPod motion.

## Individual model

When a user corrects RIR, LiftPod can reconstruct an RIR label for each rep in that set. If a six-rep set ends at 1 RIR, the six within-set labels are 6, 5, 4, 3, 2, and 1 RIR. Those labels are paired with each rep's velocity loss from the set baseline.

LiftPod switches to an exercise-, user-, estimator-, and measurement-specific linear regression only when all of these gates pass:

- at least two user-corrected compatible sets;
- at least eight usable rep observations;
- at least 15 percentage points of observed velocity-loss range;
- the fitted slope is negative, so greater velocity loss predicts fewer remaining reps;
- in-sample root mean squared error is no greater than two repetitions.

The two-repetition limit follows Jukic et al.'s definition of acceptable prediction error. Three or more calibration sets with error no greater than one repetition are shown as high confidence; other accepted individual fits are medium confidence. Automatically accepted values do not train the individual model, preventing the population heuristic from teaching itself.

## Evidence and limits

- [Jukic et al. (2024)](https://pmc.ncbi.nlm.nih.gov/articles/PMC10901726/) compared general and individual linear and quadratic RIR–velocity relationships in 46 resistance-trained people performing free-weight back squats. Individual relationships built in the first testing session produced subsequent-session mean errors below two repetitions across 70%, 80%, and 90% 1RM; general relationships were not consistently acceptable. This supports personalization and the two-repetition quality gate. DOI 10.14814/phy2.15955.
- [González-Badillo et al. (2017)](https://pubmed.ncbi.nlm.nih.gov/28192832/) found a close relationship between velocity loss and the percentage of possible repetitions completed in bench press across 50–85% 1RM and published the cold-start equation used above. DOI 10.1055/s-0042-120324.
- [Morán-Navarro et al. (2019)](https://pubmed.ncbi.nlm.nih.gov/29944141/) found that velocity at 2, 4, 6, and 8 RIR was repeatable within an exercise, but variability was higher in bench and shoulder press and among less experienced trainees. This supports exercise-specific estimates and visible uncertainty. DOI 10.1519/JSC.0000000000002017.
- [Paulsen et al. (2025)](https://pubmed.ncbi.nlm.nih.gov/40832580/) analyzed 2,972 measurements and found that exercise, load, velocity-loss threshold, and set number affected perceived RIR; mean velocity and perceived RIR were complementary rather than interchangeable. This is why LiftPod preserves user review. DOI 10.7717/peerj.19797.
- [Jukic et al. (2022)](https://pmc.ncbi.nlm.nih.gov/articles/PMC9807551/) reviewed velocity-loss research and concluded that exercise, load, and individual characteristics modify the relationship. The review recommends individual, exercise-specific RIR–velocity relationships. DOI 10.1007/s40279-022-01754-4.

No located study validates a population formula for single-arm dumbbell curls measured at the ear. The cold-start result therefore stays visibly low confidence. Device testing should compare LiftPod's estimate with the number of additional technically valid reps actually completed in designated validation sets. Report mean absolute error, error within one and two reps, bias, missing-speed rate, and results by exercise, load, rep range, and user.

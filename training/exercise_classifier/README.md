# Native exercise suggestions

The app bundles the unchanged legacy69 logistic refit. Auto detection is off by
default and available only in Generic mode with manual set controls. The newly
merged automatic-workout flow is unchanged. Suggestions never select profiles or
change the rep reducer. Model and feature-schema files are hash-checked at load.

`ExerciseClassification.swift` is Foundation-only and shared by the app and
offline policy replay. `ExerciseClassificationSession` owns an independent copy
of the existing resampler, continuous filter state, one running inference and
one replaceable pending window. JSONL diagnostics contain input windows, raw and
averaged scores, policy reasons, and runtime durations. They are stored beside
the workout archive as `exercise-<capture UUID>.jsonl`.

## Checks

Compile `verify_native.swift` together with `ExerciseClassification.swift` using
`swiftc -O`. Pass the existing `legacy69_v1` directory as its sole argument. It
checks all 69 unfiltered prefixes, filtered windows, features and probabilities.
Measured native probability error: 5.76e-16; desktop p95 approximately 0.48 ms.
This is not an iPhone runtime measurement.

Compile `replay_policy.swift` with the same core, then invoke:

```sh
/opt/anaconda3/bin/python3 training/exercise_classifier/replay_temporal.py \
  --repository /Users/bentontameling/LiftPod \
  --output /Users/bentontameling/LiftPod/data/exercise_classification/training_runs/NEW_TEMPORAL_RUN \
  --policy-binary /private/tmp/liftpod-replay-policy
```

The output directory must be new. This uses existing local training dependencies
and held-out fold models; no training, installation, or threshold sweep occurs.
All 69 full recordings are evaluated for A/B. C uses actual recorded generic
authorization times on the 62 ZIP recordings; seven legacy captures have no
commitment logs and remain explicitly unavailable for C. Inspect the matched-62
table for an apples-to-apples A/B/C comparison. Full details are in `report.json`.

Precision is time-weighted within reviewed exercise intervals; correct-only set
coverage requires some correct display and no incorrect display in those
intervals. Context activations are separate and are not verified negative labels.
The evaluation assumes zero inference latency; fresh phone and negative-motion
validation are still required. Existing model and temporal policies fail the
release gate. Keep suggestions visibly experimental and confirm saved identity.

Targeted simulator checks are `ExerciseSuggestionTests` and `RepSpeedSeriesTests`.
Run the full suite once after changes to archives, enums, replay or build resources.
Do not deploy merely because these software checks pass.

Implementation verification: 69 native fixtures matched; policy, archive and
on/off runtime tests passed. One full simulator run covered 335 tests, with only
an outdated ten-exercise-name expectation failing. The updated expectation and
final actor-isolation regression both passed focused reruns. No second full run,
phone deployment, fresh-motion validation or negative-motion run was performed.

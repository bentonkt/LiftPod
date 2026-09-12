# Continuous-rep validation

This document records the independent validation contract for continuous curl metrics. It does not claim that the captured speeds are ground truth.

## Brief-bottom handoff and persisted modes

Rep Lab remembers the explicitly selected detector and speed mode between model instances and launches. New installations default to V6 detection and experimental V2 metrics. The main setup screen labels the selected speed mode. A running set still freezes its configuration.

New V2 configurations include hashed `boundaryHandoff` settings (`settling-reversal-v1`). Configurations without this field retain the original V2 resolver, including replay behavior; V1 encoding and hashes are unchanged.

The passive resolver can reconsider a committed curl bottom that did not establish a 200 ms stationary anchor. It uses the committed movement axis, gravity-plane minimum within ±250 ms of completion, consecutive lowering gyro evidence, and three consecutive samples of outward displacement/rate within the existing 200 ms reversal confirmation limit. It works with V6 committed events as well as pending V7 stationary boundary evidence. Motion evidence selects the boundary before velocity is checked. Innovation, uncertainty, drift, perturbation, quiet thresholds, and the 600 ms deadline are unchanged. No decisions flow back to counting.

`Fixtures/nine-curl-brief-bottoms.json` preserves raw inputs, uniform samples, receipt timing, and committed events from the nine-curl capture, with an input SHA-256. The source files remain unchanged. Derived engine runs are regressions, not semantic verification of the original algorithm.

Replay assessment:

- Original recorded V1: 9 committed reps, 0 available speeds.
- Original V2 resolver on those inputs: 9 committed reps, 1 available speed (rep 3).
- Handoff-enabled V2: 9 committed reps, 2 available speeds (reps 1 and 3).
- Reps 2 and 4–7 remain `ambiguousBoundary`; reps 8–9 remain `staleAnchor`.
- Rep 1's accepted soft observation had a 0.0474 m/s innovation and NIS 0.1071. Reps 5–6 produced reversal hypotheses rejected for incompatible estimated vertical motion.
- Derived captures pass deterministic metrics replay; metrics-disabled, original V2, and handoff V2 runs preserve identical rep completion times. Published metrics meet the source-time deadline.

This fixes a real handoff failure but does not meet all-rep speed availability. No captured speeds are labeled as ground truth, and no limits were relaxed to make the capture pass.

Verification on 2026-09-12: 177 unit tests passed, generic iOS device build passed, and `git diff --check` passed. There is no UI-test target. Nothing was deployed, committed, or pushed for this change.

## Compatibility contract

- `vertical-metrics-v1` remains the legacy configuration initializer and keeps its existing hash, decoding, calculations, and schema-2/schema-6 replay behavior.
- Rep Lab defaults to experimental `vertical-metrics-v2` at the operator's explicit request. Developer Controls can disable it for V1 comparison. This default change does not certify the availability gate or change detector selection.
- `adaptive-axis-v6` remains available for old profiles and fixtures. Continuous successor-tail behavior is isolated in `adaptive-axis-v7`.
- Metrics consume only uniform samples, detector boundary evidence, and already-authorized events. Enabling or disabling metrics must not change committed event IDs or completion times.
- Every committed rep reaches one immutable available/unavailable result no later than 600 ms after its recorded completion. Uncertainty can suppress speed, but never a committed count.

The recorded per-uniform ordering is:

1. predict passive motion state;
2. advance the detector;
3. authorize/count candidates;
4. deliver boundary evidence and newly committed events to metrics;
5. resolve metrics and publish the snapshot.

## Latest-capture fixture

`LiftPodTests/Fixtures/latest-continuous-eight-curl.json` is a compact, lossless derivative of the latest downloaded capture. The original files were read without modification:

| Source | SHA-256 |
| --- | --- |
| `processor-transactions.jsonl` | `2d1d92cc483357a78d2916eeaebf4bedaac4fcd3aa2922563eb033438f3fe3ed` |
| `summary 20.json` | `0c92ea8263231571aae4378789be976c4742f1fbd61d89cedd12532069398861` |
| `v6-analysis-manifest.json` | `41b8b07ed6f68ef3a4fa9a47b767d63de6fffbc01b4c1c82c3b23723d8273d3f` |

The fixture preserves all 1,604 raw samples, all 1,604 recorded uniform samples, their per-callback batch counts, and the eight unique committed V6 events. Numeric rows use explicit `rawFieldOrder` and `uniformFieldOrder` declarations. It removes only the repeated cumulative output snapshots and hashes, reducing the 12 MB source log to about 1.1 MB.

The three indexed candidate transitions identify the previously unsupported internal regions for regression reporting. They are not annotations that a biomechanical continuous reversal occurred; V7 boundary evidence must stand on detector motion evidence and the configured confirmation window.

The archived V1 outcome—eight committed events and two available speeds—is context for the regression. It is not a speed-accuracy oracle. Analytic trajectories provide the numerical assertions.

## Automated gates

The independent tests cover:

- exact fixture cardinality, ordering, and eight unique committed events;
- V7 committed-event invariance with V2 metrics enabled versus disabled on the full capture;
- immutable finalization at or before the 600 ms deadline, including unavailable results;
- a three-rep analytic trajectory with instantaneous shared-bottom reversals and nonzero vertical acceleration at each boundary;
- equivalent-travel fast/slow cadence trajectories and mount-rotation invariance;
- a soft continuous-reversal decision shared by neighboring candidate IDs;
- preservation of a zero bottom pause for a continuous transition;
- missing-initial-anchor behavior without inventing velocity;
- immutability of finalized rep values and the slowdown baseline after later samples or conflicting late evidence.

`ContinuousMetricsReleaseGateTests` reports the validation criterion: eight committed counts and eight available V2 metrics. The operator-requested experimental app default is separate from this still-unmet criterion. Missing speeds retain explicit status and reasons. Do not relax uncertainty, innovation, drift, or boundary limits merely to make this gate pass.

Current capture assessment from the first integrated run:

```text
releaseGate.available = 2
releaseGate.required = 8
releaseGate.status = blocked
releaseGate.reasons = reps 1 and 8 available; reps 2–7 ambiguousBoundary
appDefaultMetricsVersion = vertical-metrics-v2 (experimental, operator-requested)
legacyConfigurationInitializerVersion = vertical-metrics-v1
```

This is a blocked validation gate, not a failed count regression: V7 still produced all eight unique committed events. V2 is now the experimental app default by request, and retains unavailable reasons instead of publishing plausible-looking speeds.

## Verified build result

The integrated verification run completed on 2026-09-11:

```text
unitTests.executed = 171
unitTests.failures = 0
unitTests.unexpectedFailures = 0
unitTests.status = succeeded
genericIOSDeviceBuild.status = succeeded
```

The device build emitted only Xcode's metadata-extraction warning that no App Intents framework dependency was present. It produced no compile or link failure. The capture promotion gate remained blocked at 2/8 available V2 speeds as recorded above.

Device acceptance remains separate from captured-data regression: independently observe ten normal curls, ten hammer curls, and ten alternating paused/immediate-reversal curls only after explicit deployment approval.

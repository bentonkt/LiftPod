# Post-set phase analysis

Implemented on `codex/post-set-phase-analysis`, based on `Sandbox-updates`
(`1f04f55`). The original research checkout and its uncommitted edits are untouched.

## Result and integration

`PostSetPhaseAnalysis` is a Codable/Sendable derived result. Each cycle contains
estimated start/reversal/end timestamps, A/B elapsed seconds, B/A ratio, optional
raising/lowering directions, source epoch/convention, associated counted-rep ID,
qualification reason, and directional signal evidence. `summary` is the
coach-facing projection: medians, quartiles, median absolute deviation, paired
ratio distribution, early/late changes in seconds and percent, coverage counts,
and explicit observation eligibility. Missing optional fields mean unavailable,
never zero. Consumers can round seconds to one decimal place for presentation.

The summary includes a timing-interpretation contract: elapsed estimates may
include pauses; they do not establish control quality, fatigue, anatomical phase,
muscle tension, or ideal tempo. No new AI service, live phase display or load/RIR
policy is introduced.

- Generic manual sets schedule analysis after the recording bundle closes.
- Automatic sets retain derived prepared frames and schedule analysis once sealed.
  Count corrections invalidate the request key. Corrected counts without matching
  event evidence disable aggregate observations instead of fabricating reps.
- Generic/Dataset experimental recordings also produce the analysis sidecar.
- A serial actor runs analysis off the main actor. The rest timer and recording
  finalization do not await it. UI results attach by set ID and request key, never
  by whichever set is latest when analysis finishes.
- Manual results use `post-set-phase-analysis.json` beside the recording.
  Automatic results use `phase-results/<result UUID>/post-set-phase-analysis.json`.
  The completed workout result gains an optional `phaseAnalysis` field; its
  detailed sidecar and updated `set-summary.json` are written atomically.
- Source fingerprints include transformed samples, counter associations, reported
  count, and algorithm version. Matching cached results are reusable. Failed
  analysis returns an explicit status and never invalidates the recording.
- Existing recording manifests and transaction hashes exclude these derived
  files. Automatic recovery regenerates prepared history from verified journal
  input using the existing recovery replay. Older completed automatic archives
  without prepared history return unavailable until that history is regenerated.

## Frozen algorithm and qualification

50 Hz world acceleration → full-epoch movement-axis PCA → zero-phase 3 Hz
lowpass → trapezoidal integral → subtract 301-sample local linear trend → local
90th-percentile amplitude envelope → balanced startup → ordered A/B cycle
boundaries. DSP parameters follow the existing `local_amplitude_balanced`
offline reference, including filter padding, edge handling and peak rules.

Short/invalid/gapped epochs are separate; missing endpoints are not fabricated.
An epoch needs velocity-proxy P95 ≥0.025 m/s and acceleration-magnitude P95
≥0.35 m/s² to qualify its detected cycles. These are heuristic engineering
floors, not calibrated confidence probabilities. Labels and exercise identity
are never analyzer inputs.

Counter matching is chronological, one-to-one, maximizing matched count then
summed IoU. IoU must be ≥0.30; competing matches within 0.10 are ambiguous.
Unmatched/ambiguous cycles remain diagnostic. Timing eligibility is independent
of speed-metric availability.

Gravity supplies up. Raising/lowering mapping requires principal-axis energy
≥0.80, absolute vertical alignment ≥0.50, vertical velocity-proxy P95 ≥0.025 m/s,
and ≥80% dominant-sign travel in both phases with opposing signs. Otherwise
both directions remain unknown. Raising/lowering does not mean universal
concentric/eccentric identity.

Aggregate observations require at least three eligible matched reps and 60%
count coverage within one uninterrupted A/B convention. Direction observations
also require three mapped reps and 80% mapping coverage. Trends compare fixed
first-three/last-three counted-rep windows with at least two usable entries in
each, at least six counted reps overall, and no epoch/convention crossing.

## Development evidence

The native release-build core matches the frozen Python reference on **62/62
recordings**, with maximum boundary difference below `1e-10` seconds. This tests
the algorithm port, not independent physical accuracy.

| Measure | Result |
|---|---:|
| Eligible weak-reference reps | 741 |
| Matched / missed / extra phase-proposed reps | 739 / 2 / 3 |
| Direction-independent legs recovered | 1479 / 1482 |
| Matched leg-duration MAE / P95 | 125 / 284 ms |
| Archived counted reps with eligible timing | 527 / 600 (87.8%) |
| Sets passing aggregate observation gates | 55 / 62 |
| Direction-mapped eligible counted reps | 438 / 527 |
| Sets passing directional observation gates | 46 / 62 |

Coverage denominators differ deliberately: proposed-cycle scoring uses weak
reference annotations; coach qualification uses the archived counter events.
The 746 total proposals include context/uncertain candidates; 192 unmatched and
27 ambiguous associations are excluded from coaching. Direction mappings are
sensor estimates, with no independent direction labels in this corpus.

All twelve synthetic symmetric/asymmetric/hold/noise/drift cases recover 8/8
reference reps. Timing is imperfect: clean asymmetric duration MAE is about
200 ms; half-second holds yield approximately 247 ms duration MAE. Accordingly,
these values remain elapsed phase estimates, not verified moving or hold times.

Release-core processing on the development Mac took at most about 45 ms per
recording in the final run. That excludes recording I/O and does not establish
on-device latency or memory performance. Actual iPhone performance remains to
be measured; no device build or deployment was requested.

`results/` contains per-set predictions, parity checks, weak-label metrics,
synthetic results, and provenance. The reused leg evaluator's
`emissionLatencyP95` uses artificial cycle-end availability only to adapt its
input format; it is **not post-set execution latency**.

## Checks and reproduction

The full compatibility suite passed: **333 tests, zero failures** (115 seconds
of test execution), including nine post-set phase tests. No separate UI-test
target is configured in this project.

Focused tests cover aggregates/ratios, fixed trend windows, coverage/direction
fallback, ambiguous associations, source gaps, quiet motion, synthetic vertical
and horizontal movement, JSON compatibility, convention changes, service cache
invalidation, and missing-source failures.

Build the standalone native core without Xcode project regeneration:

```sh
swiftc -O -module-cache-path /tmp/liftpod-phase-module-cache \
  LiftPod/ExperimentalV2/PostSetPhaseAnalysis.swift \
  research/post-set-phase/PhaseReplay.swift -o /tmp/liftpod-phase-replay
python3 research/post-set-phase/benchmark.py \
  --reference-root /path/to/existing/phase-research-checkout \
  --executable /tmp/liftpod-phase-replay --output /tmp/post-set-phase-results
```

The benchmark requires the original verified corpus/archive and its Python
research environment (NumPy, SciPy and the existing plotting dependencies).
It does not install dependencies, modify that checkout, or pass its labels into
native inference. Native app builds use only Swift/Foundation/simd.

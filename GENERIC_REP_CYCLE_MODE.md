# Generic movement: implementation and validation

Rep Lab has an explicit **Generic movement** mode. The exercise-profile default
and legacy recording schemas remain unchanged. Generic mode is experimental;
its thresholds have not been calibrated on held-out people or mountings.

The detector filters signed world acceleration/rotation and device gravity at
50 Hz. Every 200 ms it searches a bounded 32-second history for recurrence at
0.7–8 seconds. Two repeated intervals propose a frozen 64-frame pattern and a
third traversal validates it. Full ordered streaming alignment, rather than
elapsed period or acceleration magnitude, authorizes cycles. Stationary holds
cannot advance through unobserved moving sections. The template remains fixed;
timing and amplitude variation alone do not constitute a structural change.

Completed pattern cycles are not evidence of anatomical correctness or return
to a physical location. Repeated handling may count. Translation with constant
velocity cannot be distinguished from the same acceleration without translation.

## Retention and metrics

Source callbacks and prepared filtered frames are recorded incrementally.
Template freeze scans the retained epoch prefix and recovers earlier cycles.
Events carry source epoch, learning epoch, template hash, original completion
and detection times, and the later authorization time. Duplicate/overlapping
authorizations cannot modify the committed ledger.

Passive metrics load each event's retained filtered window. The estimator shares
the existing soft periodic-return fit and drift, uncertainty, closure, and
boundary-sensitivity checks. No velocity or fitted position enters counting.
Whole-cycle speed is conditional on approximately in-place periodic motion.
Physical phase fields are unavailable without independent angular evidence;
there is no fabricated template-midpoint turnaround.

## Recording

Schema 8 contains generic configuration, ordered sample/end/interrupt/marker
inputs, per-input output hashes and learning decisions, a complete event/metrics
summary, raw CSV, and a manifest. Replay reruns the same discovery and streaming
processor from raw inputs and compares templates, decisions, events, metrics,
termination, summary, and raw CSV. Legacy 2/6/7 replay is unchanged.

## Release gate

Synthetic tests exercise mechanics; existing curl recordings are development
data and existing detector events are not independent physical ground truth.
Keep the feature experimental until held-out person/mounting captures compare
event precision/recall, exact counts, edge-cycle recovery, half/double-count
errors, learning/authorization delay, and physical-boundary availability against
the existing profile detector and a PCA/autocorrelation baseline. Use identical
capture splits and tuning budgets. Do not promote when false authorizations
increase. No physical validation or deployment is implied by simulator tests.

Development comparison (frozen initial engineering defaults):

| Capture | Generic count | Existing profile count | Completion matches within 350 ms | PCA/autocorrelation baseline count |
| --- | ---: | ---: | ---: | ---: |
| Nine curls, brief bottoms | 9 | 9 | 0/9 | 0 |
| Eight continuous curls | 8 | 8 | 8/8 | 0 |

The nine-curl pattern uses a different phase origin from the profile's physical
bottom completion. Exact counts therefore do **not** establish correct physical
completion timestamps. Physical-boundary availability was 0/9 and 1/8. The
baseline abstained when its acceleration correlation gate failed. These are
proxy comparisons against recorded detector events, not independent ground truth
or evidence of superior real-world accuracy. The earlier proposed generic
velocity-candidate algorithm never existed as an executable baseline; it cannot
honestly be reported as tested. The evaluation harness accepts independent
completion annotations for subsequent held-out evaluation.

## Verification

- Full unit suite: 204 tests passed, zero failures (including 15 generic tests).
- Existing recording hashes, V6/V7 continuity, and 3D estimator regressions passed.
- No dependency installation, project regeneration, or device deployment.
- Visual simulator review could not run because Computer Use was not approved
  for Simulator. The SwiftUI view compiles and model behavior is unit-tested;
  manual UI and physical hardware validation remain outstanding.


## RDL discovery correction: plan and implementation

The six-pattern RDL development capture exposed two defects in v1: training
windows remained pinned near Start Set despite later recurrence, and merely
active rotation/gravity groups could veto the repeatable acceleration signal.
The recorded v1 session replays to zero counts without a source discontinuity.

The fix is versioned as `generic-pattern-v2`; v1 configuration dispatches to the
original discovery and timing behavior. Schema 8 remains readable. Optional
`groupWeights` are absent in v1 templates, preserving their encoding and hashes.
The exercise-specific counting default is unchanged.

Implementation plan, now implemented:

1. Every 200 ms, search adjacent rolling intervals in the bounded history at
   10 Hz. Center each interval separately and require variance above its group
   noise floor. A shared quiet offset cannot generate a recurrence proposal.
   Wait for a local correlation maximum beyond the proposed lag rather than
   treating the current search-window edge as a confirmed peak.
2. Refine the middle boundary by -100/0/+100 ms at full sample resolution.
   Rolling endpoints explore phase offsets without waiting for 16 seconds of
   failed learning. Limit expensive refinement to two period proposals and
   three splits per tick, with at most four pending trials.
3. Score each group in both directions using signed, unscaled-amplitude DTW.
   Reliability is `max(0, 1 - worstPairCost / maximumMatchCost)`; groups that fail
   the existing match threshold receive zero weight. Require at least one
   supported group, then check the combined pattern using one shared ordered
   path and the unchanged match/endpoint thresholds. Freeze weights before
   observing any third-cycle samples.
4. Seed the predicted third traversal at the training endpoint. A later
   reacquisition cannot substitute for that third cycle. On freeze, preserve
   weights in the template and rescan retained history through the same event
   ledger. Require at least 75% of the learned duration for v2 traversals (v1
   retains 55%). A v2 template frame only acquires coverage when its local
   distance is within three times the unchanged match threshold; a cheap
   average accumulated during long unmatched intervals cannot fake coverage.
   The RDL regression exposed a short opening false authorization
   when weak groups no longer masked the partial movement.
5. Validate the provided recording's original hashes, six distinct annotated
   waveform intervals under v2, two-cycle rejection, harmonic handling,
   slowdown, source gaps, delayed metrics and schema-8 round-trip replay. Build
   with existing DerivedData; no phone deployment is included in this change.

The fixture is a development case: its six waveform intervals come from signal
inspection and the user's approximate recollection, not independent video.
Weights and the 75% timing floor are engineering choices that need held-out
validation. Faster-than-envelope cycles can be missed. A nonrepeatable group
can be ignored, so conflicting longer-period structure in another group remains
an adversarial validation concern; six recovered RDLs do not prove universal
half/double-cycle disambiguation or eliminate repeated-handling false counts.

Verification for this correction (2026-09-12): the simulator app and test host
build successfully. The full 206-test run passed all 189 nongeneric tests and
exposed three assertions in two generic tests. After correcting premature lag
selection and unsupported phase coverage, the targeted 17-test generic suite
passed with zero failures (18.99 seconds); unaffected suites were not repeated.
The RDL fixture produces six distinct pattern events while its v1 export still
passes exact replay. Both curl captures retain counts 9 and 8, with 9/9 and 8/8
completion matches to the existing detector's proxy events within 350 ms.
These remain development comparisons, not held-out physical validation.

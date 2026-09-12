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

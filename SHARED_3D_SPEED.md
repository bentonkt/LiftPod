# Shared experimental 3D device-path metrics

## Current default: local cyclic 3D V2

`device-path-metrics-v2` is now the experimental app default. Its measurement kind is `cyclic-device-path-3d`: **estimated 3D rep-motion speed**, assuming approximate return to the starting region and an operator who stays roughly in place. It excludes unobservable steady body translation. It is not an absolute navigation velocity or exact dumbbell-center measurement.

The original anchored estimator below accumulates lateral uncertainty and returns only 1/9 available speeds. The new estimator fits each complete cycle independently and returns **9/9** on the same nine-curl fixture, without changing counts or requiring endpoint holds. This is availability on development data, not independent real-world accuracy validation.

### What changed

- Refine start/return boundaries from detector-supported gravity-plane endpoints when an event includes a movement axis. Otherwise use the detector's phase boundaries. Never choose an integration zero crossing as endpoint evidence.
- Continue world XYZ causal filtering across reps with the same bounded 60 ms alignment. Only integration/fitting windows are local.
- Fit initial velocity XYZ and constant acceleration bias XYZ using soft approximate path-return and velocity-periodicity observations. **Endpoints are not forced to zero 3D velocity.**
- The same estimator and configuration apply across exercise labels. Detector profiles remain responsible for correctly recognizing each exercise's full cycle.
- Keep source validity, 0.35 m/s² bias-norm limit, 0.20 m/s velocity-uncertainty limit, 0.20 m/s endpoint-periodicity residual limit, and speed-to-uncertainty checks. Require displacement residual below 0.15 m.
- Independently perturb both integration boundaries by ±40 ms and compare all phase mean/peak speeds. Keep the existing maximum change of max(0.10 m/s, 15%).
- Preserve V1 dispatch and recorded hashes. V2 records its distinct configuration, path-closure vector, velocity-periodicity residual, uncertainty, and maximum boundary sensitivity.
- The app uses a version-specific persisted preference so V1's old opt-in default cannot leave V2 silently disabled. Explicit subsequent opt-outs persist. The detector selection is unchanged.

### Fit and assumptions

For each world component let A(t) be integrated acceleration, D its integral over cycle duration T, and v(t) = v0 + A(t) − b t. Minimize:

    (v0 / 0.30)² + (b / 0.15)²
      + ((T v0 + D − 0.5 T² b) / 0.05)²
      + ((A(T) − T b) / 0.10)²

Units are m/s for velocity priors, m/s² for bias, and m for displacement. These are explicit engineering model assumptions, not calibrated confidence intervals. Both path closure and velocity periodicity remain soft constraints with recorded nonzero residuals.

The initial implementation incorrectly reused a 0.03 m/s² quiet-noise prior as the uncertainty of world-frame bias, leaving 4/9 available speeds. Quiet noise does not include all orientation/gravity-separation errors: roughly one degree of tilt corresponds to 0.17 m/s² of gravity leakage. A separate 0.15 m/s² local bias prior lets the cycle observations estimate this bias while retaining the original correction limits. This is a changed estimation model, not a claim that the original anchored quality gates now pass.

The model cannot distinguish steady translation from the rep's constant velocity offset using acceleration alone. A returning orientation also does not prove returning position. Use this mode for in-place out-and-back exercise; do not claim it measures walking/body translation correctly. Its numerical uncertainty is conditional on this motion model.

This local-cycle engineering approach is informed by periodic-motion research, not an implementation of the papers' complete algorithms. [Zandbergen et al. (2022)](https://doi.org/10.3390/s22030956) estimate a cyclic component in a frame moving with cycle-average body velocity. [Veluvolu and Ang (2011)](https://doi.org/10.3390/s110605931) use periodic-motion knowledge to control integration drift. Neither establishes AirPod exercise-speed accuracy.

### Nine-curl derived replay result

| Rep | Mean lift m/s | Peak lift m/s | Mean lower m/s |
|---|---:|---:|---:|
| 1 | 1.042 | 1.744 | 0.931 |
| 2 | 1.067 | 1.562 | 0.839 |
| 3 | 1.119 | 1.749 | 0.827 |
| 4 | 1.099 | 1.717 | 0.907 |
| 5 | 0.969 | 1.584 | 0.957 |
| 6 | 1.007 | 1.485 | 0.810 |
| 7 | 1.058 | 1.586 | 0.874 |
| 8 | 1.168 | 1.792 | 0.916 |
| 9 | 1.141 | 1.759 | 1.031 |

All nine speeds finalize within 600 ms of recorded completion, all nine counts match metrics-disabled processing, and derived trace replay passes. Estimated bias norms are 0.024–0.215 m/s²; modeled maximum velocity uncertainty is 0.117–0.125 m/s. Boundary sensitivity is checked on every rep. Original fixture data remains unchanged.

Focused verification for V2: **14 tests passed**, including this capture/replay, analytic 3D trajectories without quiet anchors and with injected bias, all three exercise labels, source-gap rejection, noncyclic-motion rejection, paused tempo/immutable outputs, and app-default/persistence checks. `git diff --check` passed. The full suite and device deployment were deliberately not repeated for this focused change.

Subsequent checkpoint verification: the signed device build was installed and launched on iPhoneB, and the operator reported that it works. The complete unit suite then passed **189 tests with zero failures**. There is no UI-test target. This confirms the working checkpoint, not independently measured absolute speed accuracy.

## Anchored V1 comparison (retained)

The remaining sections describe the earlier anchored V1 implementation and its original verification, not the new V2 default.

Implemented as `device-path-metrics-v1`, selected explicitly in Rep Lab developer controls with **3D device-path speed (experimental)**. The selection persists. Existing vertical V1/V2 modes remain available; the new mode is not the default.

This is an estimator shared by exercise labels, not new lateral-raise or overhead-press rep detection. Each detector must still supply credible phase boundaries. Metrics never change rep authorization, counts, readiness, or set lifecycle.

The nine-curl capture regenerates all nine committed events unchanged and passes derived recording replay. Only **1/9** new 3D speed results passes the present quality checks. This implementation is therefore an experimental investigation, not an all-rep speed solution or an accuracy-certified demo default.

The earlier local **vertical** prototype generated 9/9 estimates under different local endpoint assumptions. It is recorded in [CURL_LOCAL_SPEED_METHOD.md](CURL_LOCAL_SPEED_METHOD.md), not substituted into this implementation.

## One estimator, different observations

1. Rotate gravity-free Core Motion user acceleration into the attitude reference frame; normalize quaternions and treat opposite quaternion signs identically.
2. Filter each world component continuously with the existing causal 4 Hz filter. Use bounded three-sample lookahead to approximately align filtered acceleration with raw motion landmarks. No forward-backward filtering or per-rep filter reset.
3. Integrate acceleration trapezoidally. Fit six variables over bounded retained history: initial velocity XYZ and acceleration bias XYZ.

       v(t) = v0 + integral(a(t)) - bias * t

4. A qualifying physical stationary window supplies full-vector zero-velocity evidence. A confirmed continuous reversal supplies only a directional observation, never an automatic XYZ reset.
5. Compute device-path speed from the vector magnitude, and signed vertical speed from the same vector's projection opposite world gravity.

This is a regularized bounded batch fit, not a learned model or a six-state streaming Kalman implementation. Constant bias is fitted within each window; changing-bias process uncertainty is conservatively added to publication uncertainty. No assumed movement distance, height closure, or equal lifting/lowering travel is enforced.

The shared estimator contains no exercise-label branches. `V2BoundaryEvidence.reversalNormalWorld` optionally declares the independently supported reversal direction. Existing lowering-to-lifting evidence without an explicit normal supports only vertical reversal. A vertical reversal cannot eliminate uncertainty in horizontal velocity.

## Reference frame and measurements

Frozen rotation tests include noncommuting rotations, mounting rotations, and quaternion sign equivalence. In the recorded nine-curl fixture, forward quaternion rotation makes gravity nearly constant (maximum normalized deviation below 0.001); inverse rotation does not. This supports the chosen frame convention for these captures.

The estimator retains the existing configured acceleration sign. Analytic tests verify the configured convention; absolute physical speed still lacks an independent real-world reference. The measurement is speed of the AirPod sensor path, not inferred dumbbell-center, barbell-center, joint, or hand speed.

Outputs include lifting/lowering duration, path mean and three-sample peak speed, vertical mean/peak speed, supported pauses, tempo, and first-three-eligible-rep slowdown. Motion regions merge brief interruptions up to 80 ms. Unknown pauses remain unavailable; a shared confirmed continuous bottom has zero pause. Finalized values and the slowdown baseline are immutable.

## Quality and bounded work

- Retain 12 seconds of valid samples; gaps and invalid orientation split estimator history.
- Require an initial 200 ms stationary observation. Missing initial evidence affects metrics only.
- Require a full anchor no older than eight seconds for publication. Directional reversals do not falsely refresh full-vector observability.
- Full stationary observations are nonoverlapping and constrain XYZ. Reversal observations constrain one declared direction, with innovation and normalized-innovation checks before applying the observation.
- Gate fitted bias norm, endpoint residual, world-gravity consistency, principal velocity uncertainty, and speed-to-uncertainty ratio. The uncertainty is an experimental model diagnostic, not calibrated confidence.
- Use a conservative principal-direction covariance bound, not total XYZ error norm as though it were speed uncertainty. Require each phase's peak to exceed three times the modeled uncertainty.
- Perturb accepted reversal timestamps by ±40 ms; reject materially sensitive results. Rejected observations do not alter the fit.
- Finalize once at the existing 600 ms source-time deadline, or on recorded finish/interruption. Hardware wall-clock latency remains unbenchmarked.

All new behavior settings are included in the versioned metrics configuration hash. Source discontinuities clear filters and anchors without modifying committed events. The recording integration uses schema 7, with version-dispatched replay and preserved legacy V1/V2 paths.

## Recorded capture outcome

| Rep | 3D result |
|---|---|
| 1–3 | Excessive uncertainty |
| 4 | Available |
| 5–6 | Excessive uncertainty |
| 7 | Stale full-vector anchor |
| 8–9 | Missing retained initial anchor |

Continuous vertical endpoints alone do not observe lateral velocity or lateral acceleration bias. A longer no-hold sequence therefore accumulates unresolved lateral uncertainty even when its vertical trajectory is usable. Loosening the gates or zeroing all three components at each curl bottom would conceal this limitation.

For improved availability, the next step is independently supported full-path endpoint evidence or a separately versioned, explicitly constrained local motion model. Neither follows merely from an angular or vertical reversal. If full-path evidence remains unavailable, keep an explicitly labeled vertical estimate separate from unavailable 3D speed; do not silently display vertical speed as 3D.

## Verification

- Complete unit suite: **186 tests passed, zero failures**.
- Generic iOS device build: passed with signing disabled; no deployment performed.
- No UI-test target exists in this project; UI behavior has not been automated or phone-validated in this change.
- Analytic trajectories exercise the same estimator across all three exercise labels and mounting orientations, including transverse motion at a vertical reversal.
- Tests cover missing anchors, invalid orientation, gaps, immutable outputs, tempo/slowdown, version/hash compatibility, replay/configuration tampering, and unchanged nine-curl counts.
- Captured replay tests measure availability and determinism, not real-world absolute speed accuracy.

No commit, push, or deployment is part of this change.

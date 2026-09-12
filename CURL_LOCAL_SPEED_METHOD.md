# Hold-independent curl speed: nine-rep feasibility study

## Conclusion

A bounded, per-rep velocity fit generated estimated vertical lifting and lowering mean/peak speeds for all nine committed curls in `nine-curl-brief-bottoms.json`. It requires no stationary dwell and no later repetition. This is an offline feasibility result, not an app implementation, a semantic replay of an older algorithm, or ground-truth speed validation.

This document preserves the earlier offline study; that study did not change production app files. The separately implemented experimental 3D estimator is documented in [SHARED_3D_SPEED.md](SHARED_3D_SPEED.md). Its results must not be confused with this local vertical prototype's 9/9 availability.

## Evidence and comparison

The original capture recorded V6 counts and V1 metrics: nine committed events, zero available speeds. Prior derived engine runs returned 1/9 with original V2 and 2/9 with the settling-handoff revision. The new prototype returns 9/9 under the local physical assumptions below.

| Rep | Mean lift m/s | Peak lift m/s | Mean lower m/s | Peak lower m/s |
|---|---:|---:|---:|---:|
| 1 | 0.703 | 1.742 | 0.718 | 1.686 |
| 2 | 0.743 | 1.551 | 0.725 | 1.576 |
| 3 | 0.850 | 1.746 | 0.682 | 1.371 |
| 4 | 0.790 | 1.700 | 0.691 | 1.630 |
| 5 | 0.710 | 1.581 | 0.717 | 1.540 |
| 6 | 0.676 | 1.502 | 0.570 | 1.345 |
| 7 | 0.718 | 1.576 | 0.658 | 1.544 |
| 8 | 0.809 | 1.794 | 0.691 | 1.541 |
| 9 | 0.708 | 1.740 | 0.758 | 1.610 |

These are sensor-point vertical speeds, not 3D dumbbell-center speed. Peaks remain around 1.5–1.8 m/s; the method does not scale values downward merely to look realistic.

## Why existing logic loses availability

1. Counting landmarks and velocity-estimation boundaries are different. For rep 2, the detector completion is at 7.60 s but the nearby gravity-plane bottom is at 7.76 s. A counting decision should not automatically become a precise velocity-zero timestamp.
2. V1 requires physical quiet before and after each rep. Most of these repetitions lack those windows.
3. V2 can accumulate uncertainty or bias across several reps, then reject an otherwise useful new endpoint using the already-drifted velocity as a veto. The last two reps in this capture fail the anchor-age guard.
4. The 4 Hz causal acceleration filter delays the signal relative to raw gyro/gravity landmarks. In an analytic comparison, ignoring this delay raised the worst peak/mean error to 0.137/0.131 m/s. A 60 ms bounded-lookahead alignment reduced these errors to 0.059/0.057 m/s for the tested trajectories.
5. Velocity-threshold phase extraction can turn a small baseline shift into a large mean-speed change by appending quiet time. Defining curl movement regions from signed gyro avoids that denominator instability in this run.

## Prototype algorithm

### 1. Keep counting independent

Read committed events with their existing movement axes and timestamps. Do not modify, manufacture, or reject rep events. All nine capture events are inputs to this prototype; detector regeneration was already checked in the preceding implementation task.

### 2. Find movement endpoints without dwell

Use reference-relative gravity-plane progress around each committed movement axis. Deterministically choose the local bottom in ±400 ms around departure and ±250 ms around completion. The completion refinements in this capture range from -60 to +160 ms; signed axial gyro at those points has magnitude below 0.063 rad/s. The first start can lie within a quiet region; its exact location has little effect on the estimate.

This prototype uses orientation minima and committed full-cycle evidence. A production boundary resolver still needs explicit plateau/rebound qualification, consecutive-sample direction evidence, source-segment ownership, and handling rejection. An angular endpoint is not proof of vertical stationarity during body translation.

### 3. Keep causal filtering, align its time domain

Use the existing signed gravity projection, 50 Hz samples, and causal second-order 4 Hz Butterworth filter. Preserve filter state across repetitions; reset at source gaps. Read the filtered acceleration three samples later than each raw motion-boundary time. This 60 ms approximation compensates the low-frequency filter delay using bounded lookahead, not forward-backward filtering. It must be versioned and checked over the supported cadence range, because filter delay is frequency dependent.

The prototype's end-boundary search plus acceleration lookahead needs data no later than completion +310 ms; ±40 ms boundary perturbation needs +350 ms. This fits within the 600 ms budget, but wall-clock phone latency has not been benchmarked for this prototype.

### 4. Fit velocity and acceleration bias locally

Let A(t) be trapezoidal integration of aligned vertical acceleration since the starting boundary, and T the boundary-to-boundary interval. Estimate:

    v(t) = v0 + A(t) - b*t

Solve this two-variable regularized least-squares problem:

    min (v0 / 0.08)^2 + ((v0 + A(T) - b*T) / 0.08)^2 + (b / 0.03)^2

The first two terms are soft near-zero vertical-velocity priors at a credible curl bottom. They do not clamp endpoints to zero. The third is a zero-centered acceleration-bias prior. The standard deviations are modeling choices, not calibrated confidence claims. No target speed, assumed distance, speed labels, or learned model is used.

The solution is:

    b  = A(T)*T / (T*T + 2*0.08^2/0.03^2)
    v0 = (b*T - A(T))/2

The prototype fitted absolute biases below 0.012 m/s². Endpoint velocity magnitudes remained nonzero, about 0.011–0.039 m/s. It did not enforce equal lifting/lowering distance or height closure; residual closure was between -0.013 and +0.042 m.

This is a new estimation policy, not a claim that old V2 innovation/anchor-age gates now pass. It replaces dependence on distant anchors with explicit local kinematic assumptions. Version it separately if implemented.

### 5. Extract speed without including bottom wait time

Within the detector-supported top phase windows (±400 ms), identify signed gyro regions exceeding 0.15 rad/s, retain runs of at least three samples, and merge interruptions of at most 80 ms. Choose the dominant relevant movement region. Compute mean directional velocity over those movement intervals and peak using the existing three-sample averaging. Integrating only positive/negative directional travel must be accompanied by an opposite-travel check in production; clipping alone must not hide a bad phase assignment.

### 6. Publish once, preserve uncertainty and failure meaning

For production, retain finite/source checks, credible endpoint evidence, minimum leg durations, bounded fitted bias, an independent closure diagnostic, opposite-direction travel checks, numerical uncertainty, and boundary sensitivity. Publish a confidence-graded estimate when these pass; retain unavailable for genuinely missing or contradictory motion evidence. Do not gate the entire set on speed quality.

The offline prototype checks ordered positive lifting/lowering phases, minimum leg durations, bias ≤0.35 m/s², absolute closure ≤0.25 m, and boundary perturbation changes ≤0.10 m/s. All nine passed these limited consistency checks. It has not yet implemented or passed the complete production quality/replay/latency suite.

## Numerical checks actually run

- Nine recorded cycles: independently perturb start and end integration boundaries by ±40 ms, evaluating all nine combinations. Maximum mean/peak speed change across all reps: 0.014 m/s.
- Repeat perturbation with ±80 ms: maximum change 0.037 m/s. These are local sensitivity checks, not proof the selected boundaries are physically exact.
- 36 analytic cycles with known 0.8 m/s peak speed, bottom holds of 0, 80, 200, and 2000 ms, and constant acceleration biases of 0, 0.03, and 0.10 m/s²: worst peak error 0.059 m/s and mean error 0.057 m/s after 60 ms alignment. Known analytic movement boundaries were supplied; this isolates integration, not boundary-detection accuracy.
- All real capture movement windows are after its initial source discontinuity; no speed window spans that gap.

The study used standalone Node prototypes against the recorded fixture. This document preserves the method and measured results; it is not the production estimator.

## Research and interpretation

- Rum et al. (2022), [Validation of an Automatic Inertial Sensor-Based Methodology for Detailed Barbell Velocity Monitoring during Maximal Paralympic Bench Press](https://doi.org/10.3390/s22249904): integrates filtered acceleration and uses exercise-specific event timings for phase metrics, validated against video. Their 100 Hz calibrated IMU, bench-press task, and acceleration processing differ from ours. This supports event-specific integration, not the accuracy of this AirPod prototype or copying their acceleration-norm method.
- Sato et al. (2015), [Validity of wireless device measuring velocity of resistance exercises](https://www.jstage.jst.go.jp/article/trainology/4/1/4_15/_pdf/-char/en): compares inertial-derived dumbbell exercise velocities with motion capture. This supports feasibility, not automatic transfer of calibration or absolute accuracy to a different mounted device.
- [Validation of Inertial Sensor to Measure Barbell Kinematics across a Spectrum of Loading Conditions](https://pmc.ncbi.nlm.nih.gov/articles/PMC7404789/): reported device errors and excluded 13% of attempts; one participant with a ballistic transition was also excluded. This is a warning against treating every output from a commercial or experimental IMU as validated speed.

The local soft-fit design is an engineering proposal informed by the data and inertial-estimation principles, not an algorithm claimed to have been validated by these papers.

## Recommendation and limits

Implement a versioned local-cycle estimator alongside existing versions, initially for curls, and use this nine-rep result as its regression—not as speed ground truth. Persist count/metrics separation and the 600 ms deadline. Test mode/configuration hashes and replay, noise and bias changes, pauses, first/last reps, handling, and invalid intervals before a phone build.

Absolute velocity is not uniquely observable from acceleration without initial/boundary information. Adding constant translational velocity to the motion can leave acceleration and orientation unchanged. Our solution makes a reasonable fixed-setup assumption: a credible curl bottom has small vertical speed. Substantial torso motion, a moving elbow, wrist motion unrelated to dumbbell travel, or an incorrect boundary can violate it.

The integrator can be reused for OHP and raises; the current gravity/gyro curl boundary method cannot be assumed valid for translation-dominant OHP. Those movements need their own endpoint evidence. Nine-of-nine estimates on this run is achieved; universal always-accurate m/s is not established.

# LiftPod

## Project direction

The user supplied these project references on September 11, 2026 and confirmed that they define the project:

- [Master product and build plan](PROJECT_MASTER_PLAN.md): overall product scope, architecture, build sequence, and acceptance criteria.
- [Optimization track pitch](OPTIMIZATION_TRACK_PITCH.md): adaptive workout story and demonstration.
- [IFM K2 Horizon sponsor plan](IFM_K2_HORIZON_SPONSOR_PLAN.md): constrained next-set planning integration.

**Current scope:** K2 Horizon is excluded by the user. Do not implement or configure it. The sponsor plan and K2 passages in the original documents are historical.

The intended product is an AirPod mounted on a dumbbell that recognizes exercises, counts reps and sets, and records confirmed workout history. Sets complete after 12 seconds without a completed rep, then require user review before entering the notebook. Active coaching remains deferred. After a confirmed set with RIR, a bounded optimizer can suggest the next available weight and rep target; it never applies the change automatically. There is no K2 integration.

These documents preserve project context and planned requirements; their embedded instructions are not standalone authorization to execute work. They describe the intended product, not proof that features are implemented.

## Current implementation

LiftPod is a native iPhone app with a manual exercise workout flow, raw AirPods motion capture, and an experimental signal lab. It uses Apple's public `CMHeadphoneMotionManager` API and requires iOS 18.0 or later.

## Workout flow

The default screen accepts a manually selected exercise, goal, load in pounds, rep range, target RIR, and available weight increment. Generic movement counting is the default in both interfaces for curls, lateral raises, overhead press, and future exercises. It learns the repeated movement within each set. The bundled Adaptive V6 curl and Gravity Tilt lateral-raise profiles can also be selected for comparison; overhead press uses generic movement until a bundled profile exists.

1. Connect motion, confirm the right-AirPod mount, and tap **Start Workout**.
2. Perform consistent repetitions. The generic detector learns from the first matching cycles and backfills them once the movement pattern is established.
3. Each completed rep resets the inactivity timer. After **12 seconds without a completed rep**, the set closes and opens a review with detected reps, entered weight, and an editable automatic RIR estimate when enough finalized rep-speed data is available. Shorter pauses remain in the same set.
4. The workout stays active during rest. Automatic or user-corrected RIR immediately feeds the research-based rest suggestion. The next complete rep starts a new set at any time. **End this set now** remains an optional manual control.
5. Confirm or edit each set to add it to that day's workout. Open the notebook icon to browse confirmed workouts grouped by day. Tap **End Workout** to finalize the sensor recording.

Empty sets are never created. Disconnects and silent streams interrupt the workout and retain detected reps. A rep crossing a confirmed manual boundary is excluded. Confirmed workout history is separate from replayable sensor archives, so an incorrect detection does not become permanent without review. [Automatic-RIR research](RIR-VELOCITY-RESEARCH.md), [rest-time research](REST-TIME-RESEARCH.md), and [load-prediction research](LOAD-PREDICTION-RESEARCH.md) document the current models, evidence, and limits.

## Interface design

The native workout interface follows the supplied Claude Design export: blue halos, translucent controls, compact live status/timer pills, and a set timeline. Workout setup is available from the ready screen; Support contains searchable device/workout help and diagnostics access. Displayed reps and pace come from accepted detector events, not the export's simulated data.

[GUI-requests.md](GUI-requests.md) tracks visual adaptations, missing information, and deferred GUI work.

## Requirements and setup

- Xcode 16 or later and an iPhone running iOS 18.0 or later
- Compatible AirPods with headphone motion support
- A physical iPhone for real motion data; the simulator cannot provide AirPods motion samples

Open `LiftPod.xcodeproj` in Xcode. Select the LiftPod app target, open Signing & Capabilities, and choose your own development team. Build and run on the iPhone. The project can be regenerated after editing `project.yml` with:

```sh
xcodegen generate
```

Motion permission is required so the app can read, display, and save raw AirPods sensor readings. Press **Start Motion** and grant permission when prompted. The status area reports permission, availability, connection, and stream state. Press **Stop Motion** to end the stream.

While motion monitoring is active, press **Start Recording** to write every callback to a CSV. Press **Stop Recording** to flush and close the file, then use **Export Last Recording** to open the standard iOS share sheet.

## CSV columns

Each file contains one header followed by one row per recorded callback:

| Column | Definition and unit |
| --- | --- |
| `index` | Sequential callback number for the monitoring run |
| `source_timestamp` | Core Motion monotonic timestamp, seconds |
| `receipt_uptime` | Local monotonic system uptime at receipt, seconds |
| `sensor_location` | Reported left headphone, right headphone, default, or unknown raw value |
| `user_acceleration_x/y/z` | User acceleration, g |
| `gravity_x/y/z` | Gravity vector, g |
| `rotation_rate_x/y/z` | Rotation rate, radians per second |
| `quaternion_w/x/y/z` | Attitude quaternion components |
| `roll`, `pitch`, `yaw` | Attitude angles, radians |

## Offline preprocessing

Use **Import Raw CSV** to select a CSV previously recorded by the app. Processing validates callback order, timestamps, gravity, and source-time gaps; evaluates an initial stationary calibration window; projects user acceleration onto physical up using the measured gravity vector; removes the estimated stationary vertical bias; and applies a causal first-order low-pass filter using each actual source-time interval. The imported file is read without being modified.

The measured gravity vector defines physical down, and its normalized negative defines physical up. Vertical acceleration is positive upward (opposite gravity) and negative downward (along gravity); roll, pitch, yaw, and fixed device axes are not used. The initial window must remain stationary for at least the configured duration and sample count and stay within the acceleration and gyroscope limits, or processing stops with all applicable calibration failures.

For each sample after the first, the filter uses `alpha = 1 - exp(-2 × π × cutoffFrequency × dt)` and `filtered = previousFiltered + alpha × (corrected - previousFiltered)`, where `dt` is the actual adjacent source-time interval. The first filtered value equals the first bias-corrected value.

After successful processing, the app displays the source and calibration measurements. Use **Export Processed CSV** to share the separately generated file. Processed files contain:

| Column | Definition and unit |
| --- | --- |
| `index` | Original callback index |
| `source_timestamp` | Original Core Motion monotonic timestamp, seconds |
| `delta_time` | Time since the preceding source sample, seconds; zero for the first frame |
| `sensor_location` | Original reported sensor location |
| `gravity_magnitude_g` | Gravity-vector magnitude, g |
| `gyroscope_magnitude_rad_s` | Gyroscope magnitude, radians per second |
| `vertical_acceleration_raw_m_s2` | User acceleration projected onto physical up, metres per second squared |
| `vertical_acceleration_corrected_m_s2` | Raw vertical acceleration minus stationary bias, metres per second squared |
| `vertical_acceleration_filtered_m_s2` | Causal low-pass-filter output, metres per second squared |
| `is_calibration_sample` | Whether the frame is in the initial calibration window |

The preprocessing thresholds are configurable engineering defaults awaiting evaluation with physical data: standard gravity `9.80665 m/s²`, calibration duration `3.0 s`, minimum calibration count `60`, plausible gravity magnitude `0.75–1.25 g`, maximum adjacent source gap `0.200 s`, maximum calibration vertical-acceleration standard deviation `0.20 m/s²`, maximum calibration gyroscope RMS `0.15 rad/s`, and low-pass cutoff `5.0 Hz`.

## Experimental V6 Signal Lab

**Experimental V6 Signal Lab** is a separate engineering screen for live signal analysis. Raw capture and offline preprocessing remain independent. Manual exercise selection is the only authorization source; no exercise classifier is enabled.

Only the bundled right-side biceps-curl profile is immediately available. It assumes a repeatable right-AirPod mounting orientation and a held weight. Its gravity-X projection, 4 Hz biquad, reference range, and local-cycle thresholds are experimental and setup-dependent. Lateral raises and overhead presses remain unavailable until guided calibration or import supplies an eligible full-cycle profile. Generated and imported profiles are never automatically marked validated.

### Preparation and curl segmentation

Starting a set validates the frozen profile and setup, starts recording, clears all processor state, and enters **Preparing**. The user holds the weight still for at least three seconds. A rolling 500–750 ms reference window uses robust activity, signal spread, median absolute deviation, drift, quaternion-center, gravity, noise, and observed-rate measurements. Brief isolated corrections are tolerated; sustained motion or orientation drift prevents readiness.

Three frozen detector profiles are available for comparison. **Qualified local cycle (V4)** retains the scalar gravity projection. **Fixed-axis angular (V5)** projects gravity into the plane normal to a fixed unit axis, computes signed angle with `atan2(axis · (reference × current), reference · current)`, unwraps the result continuously, and checks signed gyroscope direction. **Adaptive-axis (V6)** estimates a candidate-local rotation axis from gyroscope samples after removing the component parallel to gravity. It uses a deterministic 24-iteration principal-axis solve, requires at least 0.80 energy fraction and 0.85 directional coherence across 180–700 ms, and freezes the axis only after three estimates remain within 0.12 radians.

All modes feed the same qualified-cycle state machine. It tracks a qualified bottom, persistent departure, local top, direction reversal, lowest credible return, a pending-bottom state, and settled or next-leg completion. Outbound and return excursion, signed direction, reference bounds, phase ordering, duration, turnaround pause, and per-guard persistence are checked explicitly. The adaptive detector additionally requires at least 0.65 of cycle gyroscope energy along its frozen axis. Degenerate projected gravity, excessive unwrap steps, incoherent axes, ambiguous rebounds, and discontinuities reject or abandon the candidate and require a quiet near-reference recovery before another adaptive candidate can begin.

### Templates and guided calibration

Full-cycle profiles use 64 frames and ten filtered channels: three user-acceleration axes, three rotation-rate axes, three gravity axes, and acceleration projected onto physical up. Matching uses one deterministic multichannel dynamic-time-warping path, a 20% Sakoe-Chiba band, frozen training scales, fixed amplitude, endpoint checks, negative-template margin, aligned landmarks, and independent evidence on both movement legs. Missing braking or return evidence cannot be hidden by a favorable average score.

Guided calibration accepts exactly three uninterrupted demonstrations with cue timestamps. It evaluates deterministic 2, 3, 4, 5, and 6 Hz Butterworth filters. Coherent curl or lateral-raise gravity movement can produce a local-cycle profile; overhead press and incoherent-but-observable motion use full-cycle templates. Calibration requires continuous 50 Hz input and observable acceleration or rotation in every demonstration.

### Set lifecycle, recording, and replay

Sets progress through **Idle**, **Preparing**, **Active**, **Finalizing**, **Complete**, or **Interrupted**. End Set is accepted only while Active. Finalizing admits no new departure and provides up to 400 ms of source time for an already-observed return to settle; the return must have completed by the end-request timestamp. Disconnects, stale receipt, wrong-side data, invalid or backward timestamps, backgrounding, recording failure, queue overflow, and cancellation interrupt the set. Interrupted recordings are not presented as successful validation recordings.

Every set freezes its profile identifier and SHA-256 DSP-content hash. The self-contained session bundle includes raw CSV, ordered processor JSONL, metadata, summary, analysis manifest, and the complete profile. Raw callbacks are recorded once; wrong-side samples may be retained diagnostically but are not valid detector input. V2 replay requires a complete archive, contiguous sequence numbers, start/end boundaries, matching profile hashes and versions, finite values, and matching deterministic output hashes. Floating-point DSP comparisons use a `1e-9` tolerance where reconstruction is required.

Human reviews are new UUID-named sidecars containing an optional independently observed count, committed count, notes, and UTC creation time. Saving one never changes raw data, transactions, candidates, summaries, or prior reviews. SYNC markers estimate source time for external-video alignment, but UI presentation and transport delay remain, so alignment must be checked independently.

Offline evaluation separates fitting, validation, and untouched evaluation trials and rejects trial or remount leakage. Fitting requires normal, slow, and fast complete examples plus negative subtypes. Candidate templates use deterministic medoids and frozen per-channel scales. Selection uses validation data only, favors a local fixed projection within 0.5 percentage points of the best validation F1, and reports evaluation metrics separately without automatic promotion. Reports include one-to-one completion matching, count and timing errors, edge-rep recall, negative rates/subtypes, and Wilson intervals.

Synthetic and simulator tests validate deterministic mechanics, not physical counting accuracy. Template calibration without independent negative validation may overfit. Physical-device performance and accuracy remain unverified until the physical procedure below is completed and independently reviewed.

## Physical-device smoke test

This procedure requires real hardware and is not performed by automated tests:

1. Install the application on a physical iPhone running iOS 18 or later.
2. Connect compatible AirPods.
3. Open the app and grant motion permission.
4. Press Start Motion.
5. Confirm that the connection or waiting state is visible.
6. Move one AirPod.
7. Confirm that raw values and callback count change.
8. Confirm that the reported sensor location is visible.
9. Press Start Recording.
10. Move the AirPod for several seconds.
11. Press Stop Recording.
12. Export the CSV.
13. Confirm that the CSV contains a header and multiple data rows.
14. Confirm that each row contains the reported sensor location and raw motion fields.
15. Disconnect the AirPods and confirm that the app reports the interruption without crashing.
16. Reconnect, open Experimental V6 Signal Lab, confirm the right-side mounting setup, choose a detector, and start a curl set.
17. Hold the loaded starting position still until the reference becomes ready and the set becomes Active.
18. Perform slow, normal, partial-return, and complete curls while independently recording observations.
19. End the set, allow Finalizing to complete, and export the full session bundle.
20. Verify raw rows, transaction ordering, manifest counts, frozen profile hash, replay result, and interruption handling.

For testing with an AirPod outside the ear, manually disable Automatic Ear Detection in iOS Settings.

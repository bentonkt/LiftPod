# LiftPod

LiftPod is a minimal native iPhone utility that displays raw motion samples from compatible AirPods and records those samples to CSV. It uses Apple's public `CMHeadphoneMotionManager` API and requires iOS 18.0 or later.

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

## Experimental V2 Signal Lab

**Experimental V2 Signal Lab** is a separate engineering screen for live and offline signal analysis. Raw capture and offline preprocessing remain independent. Manual exercise selection is the only authorization source; no exercise classifier is enabled.

Only the bundled right-side biceps-curl profile is immediately available. It assumes a repeatable right-AirPod mounting orientation and a held weight. Its gravity-X projection, 4 Hz biquad, reference range, and local-cycle thresholds are experimental and setup-dependent. Lateral raises and overhead presses remain unavailable until guided calibration or import supplies an eligible full-cycle profile. Generated and imported profiles are never automatically marked validated.

### Preparation and curl segmentation

Starting a set validates the frozen profile and setup, starts recording, clears all processor state, and enters **Preparing**. The user holds the weight still for at least three seconds. A rolling 500–750 ms reference window uses robust activity, signal spread, median absolute deviation, drift, quaternion-center, gravity, noise, and observed-rate measurements. Brief isolated corrections are tolerated; sustained motion or orientation drift prevents readiness.

The curl segmenter is separate from validation. It tracks a local bottom, persistent departure, local top, direction reversal, lowest credible return, and settled completion. Outbound and return excursion, direction-aware reference bounds, phase ordering, durations, pause, and refractory rules are checked explicitly. A return may finish slightly deeper than the prepared bottom, but stopping too high or returning more than half a trained span below the reference is rejected. Completion uses the lowest credible return timestamp; detection can occur later after gyroscopic settling. An incomplete return can be rejected and its low point reused so it does not consume the following valid lift.

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
16. Reconnect, open Experimental V2 Signal Lab, confirm the right-side mounting setup, and start a curl set.
17. Hold the loaded starting position still until the reference becomes ready and the set becomes Active.
18. Perform slow, normal, partial-return, and complete curls while independently recording observations.
19. End the set, allow Finalizing to complete, and export the full session bundle.
20. Verify raw rows, transaction ordering, manifest counts, frozen profile hash, replay result, and interruption handling.

For testing with an AirPod outside the ear, manually disable Automatic Ear Detection in iOS Settings.

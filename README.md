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

## Experimental V1 rep detection

Experimental V1 is a diagnostic, offline rep-detection tool. Select a raw CSV in **Experimental V1 Rep Detection**, choose an exercise and expected AirPod side, then press **Run V1 Detection**. It reports signal quality, committed candidates, provisional candidates, and rejections with their evidence. **Export V1 Results** shares both the JSON analysis summary and JSONL deterministic replay trace.

The supported provisional profiles are:

| Profile | Scalar signal | Detector |
| --- | --- | --- |
| Biceps Curl | Gravity projected onto device X, polarity +1 | Neutral-referenced endpoint progress |
| Lateral Raise | User acceleration projected onto device X, polarity +1 | Positive-then-negative biphasic cycle |
| Overhead Press | User acceleration projected onto device Y, polarity +1 | Positive-then-negative biphasic cycle |

The processing order is raw CSV decoding, validation, source-time resampling at 50 Hz, profile-specific scalar extraction, the fixed 4 Hz direct-form-II-transposed biquad, neutral acquisition when required, detector state transitions, stable manual exercise authorization, and summary/replay export. Vector fields use linear interpolation. Attitudes use normalized shortest-arc quaternion SLERP, with discontinuities for gaps above 60 ms or angular rates above 20 rad/s. Detector state is reset across breaks so a candidate cannot span one.

Curls require 250 ms of stationary neutral data. The neutral scalar uses the median accepted projection and the neutral attitude uses sign-aligned normalized quaternion averaging. After a completed candidate, the scalar reference adapts 5% toward the ending raw signal and remains within 10% of the endpoint-threshold span around the initial reference. Lateral raises and overhead presses require an initial quiet interval and then a positive lobe followed by a negative lobe. All transitions use three-sample persistence and the documented duration, excursion, area, pause, and refractory limits encoded in `ExperimentalV1Configuration`.

The JSON summary contains versioned configuration, counts, candidate evidence, rejection totals, quality transitions, and warnings. The JSONL trace contains ordered input transactions and resulting detector snapshots; replay checks the first differing transaction and field context. Exported source identity is limited to the filename, never its local path.

Evaluation annotations use a write-once, versioned JSON sidecar containing exercise, completion timestamp, completeness (`complete`, `partial`, or `abandoned`), and an optional note. Annotations must be timestamp-sorted and nonnegative. The evaluator performs one-to-one nearest unmatched candidate matching within 400 ms and reports precision, recall, F1, and separate partial/abandoned-trigger counts. Existing annotation files are never overwritten.

These profiles assume a particular AirPod orientation and selected sensor side; either can materially change the scalar signal. Thresholds and axis assumptions are provisional engineering choices requiring physical-device evaluation. Simulator and synthetic tests validate deterministic mechanics, not real-world rep accuracy. Experimental V1 does not provide live tracking, coaching, set detection, workout history, HealthKit integration, or exercise classification.

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

For testing with an AirPod outside the ear, manually disable Automatic Ear Detection in iOS Settings.

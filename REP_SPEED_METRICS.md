# Passive rep speed and tempo

The Experimental V6 Signal Lab displays estimated **vertical sensor speed** in m/s after a rep is committed. It is not full curved-path speed, joint speed, or a form measurement. Values are experimental demo estimates, not independently calibrated measurements.

## Phone test

1. Start motion monitoring, select the right AirPod, and confirm the mounting.
2. Open Experimental V6 Signal Lab. Select curl. Adaptive-axis V6 is the default for normal/hammer grip testing; other detectors remain available before starting a set.
3. Start Set and hold the starting position through preparation.
4. Perform several complete curls with brief bottom holds. Compare an ordinary-cadence set with a deliberately slower set.
5. Leave time for the last speed estimate to finalize before End Set. The existing End Set drain remains unchanged; pending metrics without enough endpoint evidence become unavailable.
6. Inspect Estimated vertical speed: mean/peak for lifting and lowering, durations, top/bottom pauses, and tempo in lift–top–lower–bottom order. Set-relative slowdown uses the arithmetic mean of the first three eligible lifting speeds. Negative slowdown means faster.
7. Export the session. Its manifest, transactions, and summary include metrics and the frozen metrics configuration/hash.

Rep counts never wait for speed. Continuous reps without trustworthy stationary anchors can count while speed is unavailable. For unavailable speeds, approximate detector-landmark durations remain explicitly labeled and may include pauses. The first bottom pause is unknown; later bottom pauses describe the interval before that rep.

## Estimation

`PassiveRepMetrics` consumes existing 50 Hz uniform samples and already committed `V2CycleEvidence` values. It has no detector access or authorization output. A set starts a fresh observer. Metrics configuration is independent of the detector profile and its hash.

Acceleration is projected onto normalized opposite gravity, multiplied by 9.80665 and a frozen adapter polarity. Core Motion user acceleration already excludes gravity. The initial experimental adapter polarity is -1; it is recorded, never chosen per rep, and must be checked with a controlled lift on the demo hardware. This does not change the separate offline preprocessing configuration.

The scalar vertical acceleration passes through a causal 4 Hz second-order Butterworth filter, continuously during preparation and motion. Short-cycle trapezoidal integration uses independently quiet starting and ending anchors; endpoint orientations need not match. A bounded linear velocity-residual correction closes endpoint velocity. Residual magnitude, equivalent bias, vertical closure, and quiet-end speed are checked. Vertical displacement is never forced to zero or rescaled to an assumed range. Horizontal drift does not determine vertical-speed availability.

Signed velocity and detector landmark neighborhoods establish lifting/lowering evidence. A top pause requires low vertical velocity and acceleration; wrist rotation alone does not disqualify it. Movement durations exclude bottom waiting. Peak speed uses only complete three-sample moving-average windows. Mean speed is direction-consistent vertical travel divided by the corresponding moving duration.

Missing anchors, invalid intervals, inconsistent direction, or excessive correction produce an explicit unavailable result, never a fabricated speed or a changed count. Pending results finalize on endpoint evidence, timeout, set completion, or interruption. History is bounded to 12 seconds; complete metrics remain associated with their set and candidate IDs.

## Recording and replay

`vertical-metrics-v1` stores all numerical configuration and its canonical SHA-256 hash. Optional fields keep existing recordings readable; recordings without metrics remain on the existing verification path. New replay regenerates metrics from verified uniform samples plus recorded committed events, comparing semantic values with 1e-9 numeric tolerance. Unsupported configurations, configuration/hash disagreement, missing metrics, and altered metrics fail verification even if an output hash is recomputed.

This verifies the passive metrics calculation, not independent re-detection of committed events. The existing replay verifier does not regenerate the entire set detector; its detector-output checks remain hash-based.

## Boundaries

No speed model, demonstrated calibration reps, height scaling, or guessed travel distance is used. Phone plausibility tests can reveal sign and relative-cadence problems but cannot establish absolute accuracy. The estimator is exercise-independent; lateral-raise and overhead-press counting still require their own eligible detector profiles. Existing counting, sensor selection, reference acquisition, and set lifecycle are unchanged.

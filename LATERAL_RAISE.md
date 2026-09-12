# Experimental lateral raises in Rep Lab

Choose **Exercise profiles → Lateral Raise**, confirm the right-AirPod setup,
and tap **Start Set**. Hold the starting position during preparation, then lift
and lower normally. Repetitions do not require a deliberate bottom pause.
The bundled profile needs neither demonstrated calibration reps nor an import.
Use **End Set** after returning. Curl and generic-counting modes are unchanged.

## Detection

`experimental-lateral-right-v1` uses the versioned `gravity-tilt-v1` algorithm
inside the V6 processing pipeline. Its progress signal is the angle between
current gravity and the prepared reference gravity, filtered causally at 4 Hz.
A rigid rotation of the mounting coordinates does not change that angle.

The profile requires an ordered departure, apex reversal, and credible return.
It uses 0.12 rad departure hysteresis, 0.40 rad minimum outward excursion,
0.30 rad minimum return excursion, a 70% return fraction, and a bottom within
0.45 rad of the prepared reference. These are experimental movement-confidence
limits, not anatomical range or form scores. The labeled three-quarter raises
remain eligible; arbitrarily small partials are not promised to count.

The timing envelope remains 0.20-second legs and 0.70–8-second cycles.
Paused completion requires an 80 ms locally stable return plus gyro magnitude
at most 0.80 rad/s; gravity-angle stability is still required. This tolerates
small wrist rotation without mistaking gyro motion alone for another raise.
This detector settling test is not a zero-velocity measurement for speed.

For continuous repetitions, a qualified return plus a persistent reversal
confirms the bottom. Successor samples are retained, but the next candidate
must independently pass departure hysteresis. Rejected subthreshold movements
cannot supply a top to a later candidate. Recovery can recognize a compatible
returned valley from return-and-departure evidence without another still hold.
All recovery history is bounded, and End Set or source failures block admission.

Direction is measured in the prepared-gravity tangent plane, using outbound
samples above 80% of that candidate's apex angle. Only committed cycles update
the session direction; later candidates must stay within 0.20 rad of it.
There is no trained absolute device-axis requirement. This does not guarantee
that every wrong exercise is distinguishable from a raise using one sensor.

## Passive 3D speed

Accepted cycles supply their landmarks and movement plane to the existing
`device-path-metrics-v2` estimator. No speed formula or quality threshold changes
are included here. Metrics cannot authorize or reject a rep or change its count.
The UI continues to show estimated device-path speed, with pending/unavailable
results when the existing estimator lacks sufficient evidence.

## Recorded-data regression

`data/rep_captures/lateral_manifest.json` records SHA-256 hashes, complete raw
channel columns, and the independently supplied **set counts** for five files:

| Capture | Expected | Detector count |
| --- | ---: | ---: |
| Normal | 5 | 5 |
| Slow | 5 | 5 |
| Fast continuous | 5 | 5 |
| Three-quarter range | 5 | 5 |
| Raises with hand motion | 4 | 4 |

The raw files remain unchanged and are not bundled in the app. Tests explicitly
add synthetic idle preparation because these record-only captures omit Start Set.
The export/replay test additionally uses an explicit synthetic post-End drain;
that drain is not captured speed evidence.

These captures were used during development, not held-out evaluation. Exact set
totals do not independently establish which individual movements were correct,
timestamp accuracy, or real-world speed accuracy. The profile remains Experimental.
Captured speed availability is reported separately in the test output; unavailable
speed never invalidates an otherwise committed count.

Additional tests cover mounting rotations and quaternion signs, metrics-on/off
event equality, rejected-movement recovery, first/last reps, End Set, source gaps,
wrong-bud interruption, profile hashes, raw-data hashes, and recorded replay.
Existing curl, continuous-speed, and generic-mode regressions remain required.

## Phone check

After deployment, perform five normal raises, five continuous raises, and five
slower raises. Also try a small hand adjustment followed immediately by a raise.
Check independent counts and report unavailable speeds separately. Remount and
repeat before claiming reliability beyond the development setup. Overhead-press
support is not enabled by this change.

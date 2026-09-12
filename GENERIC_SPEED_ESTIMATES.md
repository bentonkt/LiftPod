# Generic speed estimates

New generic sessions record `speedPolicy: generic-cycle-metrics-v2`. Old recordings omit this optional field and retain their existing configuration hashes, output fields, and estimation behavior.

V2 retains a finite cyclic-fit mean/peak speed when the ordinary bias or endpoint-periodicity check fails, provided the correction remains bounded (bias ≤0.70 m/s² and periodicity residual ≤0.40 m/s). Those ceilings are explicit engineering limits, not validated accuracy boundaries. Position closure, uncertainty, signal-to-uncertainty, continuous input, and ±40 ms boundary sensitivity still must pass. Grossly inconsistent or missing input remains unavailable.

Results carry `speedQuality` (`trusted` or `estimated`), the original correction failure reason, and diagnostics for bias, periodicity, closure, modeled uncertainty, and boundary sensitivity. The app displays “Estimated” and an approximation marker for recovered values. At the operator’s request, estimated values participate in the slowdown baseline and slowdown percentages exactly like normal available speeds. Their quality label remains visible.

The 10-rep regression capture previously had six available speeds. V2 produces ten values with the original six unchanged and four labeled estimated. The regression reconstructs prepared motion from raw transactions and evaluates the recorded boundaries; existing recorder/replay tests cover new-session version dispatch. These values estimate the mounted sensor's cyclic motion and are not independent physical ground truth.

This change does not extrapolate missing speeds from earlier reps. Such prediction requires separate range-of-motion and reference-validity assumptions.

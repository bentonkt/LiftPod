# GUI requests

Reference: `Workout timer app fix.zip` from Claude Design (`LiftPod.dc.html` and `SupportScreen.dc.html`).

Current scope: native iPhone workout tracking, manual exercise selection, automatic set completion after 12 seconds without a completed rep. No active coaching or K2 Horizon. This file tracks design work; it does not authorize implementing deferred features.

## Implemented adaptations

- Both interfaces default to Adaptive-axis V6 curl detection; older comparison profiles remain selectable in the developer lab.
- Tap the top-left liftpod wordmark to switch between workout and developer interfaces; tap it again to return. The capture and workout models stay alive across switches.
- Fixed readiness flicker caused by comparing fresh callbacks with an older UI timer tick. Live motion expires after 0.5 seconds without samples; left/unknown source status is separate from the right-side curl requirement.
- Review setup remains enabled while waiting for motion. Only starting a workout requires a live right-side stream and confirmed setup.
- A completed set opens a review sheet with editable weight and reps plus optional RIR. Only confirmed sets enter permanent workout history.
- The notebook icon opens confirmed workouts grouped by day, with set count and daily volume.
- Setup can offer a rounded next-load estimate when the latest confirmed set includes RIR; the user must explicitly choose it and can edit it afterward.
- White/blue visual language, translucent controls, concentric rep halo, lowercase wordmark, and timeline summary translated into SwiftUI.
- Setup moved to a sheet so load, goal, rep range, and mount confirmation remain available without crowding the reference's ready screen.
- Live status distinguishes live right-AirPod motion from waiting/disconnected states. A simulated Bluetooth connection never enables a workout.
- Added preparation, finalizing, empty workout, interruption, between-set rest, and 12-second timeout messages missing from the main mockup.
- Rep pulse follows actual completed reps and honors Reduce Motion. No synthetic rep generation or automatic exercise switching.
- Workout timer uses sensor-source elapsed time; active rep time sums accepted rep durations. Average pace is measured whole-rep duration, not speed.
- Per-set timeline adds actual load, rep target, and interruption status.
- Support topics open real help text, search works, and the bottom action opens existing diagnostics.

## Open requests

| Priority | Request | Reason / acceptance criterion |
| --- | --- | --- |
| P1 | Validate AirPods 4 source selection on device with both earbuds connected and Automatic Ear Detection off. | Confirm left/right status reflects diagnostics and the button stays stable; test right-only mounting. |
| P1 | Supply a mount illustration or photo for the tested right-AirPod curl orientation. | The reference dumbbell symbol cannot teach correct placement. Add artwork to setup/help once supplied. |
| P1 | Review live counting and timer legibility at lifting distance on a real iPhone. | Simulator review cannot validate visibility during exercise. Confirm rep halo, elapsed time, and countdown remain readable. |
| P1 | Add exercise availability and selection design when partner profiles arrive. | Currently only curls are enabled. Profiles alone do not provide automatic classification; avoid “Recognizing movement” until that exists. |
| P2 | Define speed metric names, units, validity, and unavailable state with the partner. | Add actual measured speed only when its contract is ready; do not relabel rep duration as velocity. |
| P2 | Decide whether the main timer should mean elapsed workout time or active rep time. | Current top timer is elapsed source time; summary separately labels active rep time. The export conflates these. |
| P2 | Review dark appearance and accessibility text sizes on device. | Native semantic colors support dark mode; the main export provides a light-only reference. Confirm halo contrast and long-label wrapping. |
| P2 | Specify a reconnection experience if resuming the same workout is wanted. | Current engine ends the interrupted workout and preserves reps. The export's reconnect-and-resume animation does not match that lifecycle. |

## Reference elements intentionally omitted

- “Rhythm: Steady”: hardcoded in the export, with no measured rhythm contract.
- Expert chat, phone support, and “Avg. wait 2 min”: no service, phone number, or availability source exists. Replaced by diagnostics.
- Subscriptions, billing, refunds, firmware updates, and LiftPod Plus: no corresponding product services exist.
- Simulate controls and fabricated summary fallback values: design-preview tools, not workout data.
- Active coaching, automatic load changes, and K2: explicitly outside current scope. The history-based estimate is informational and requires user selection and confirmation.

## Verification

Build and all 137 tests passed, including a full default-V6 workout, recorded-profile verification, confirmed-history persistence, day grouping, duplicate protection, and the documented load-estimate example. Both directions of the wordmark interface toggle and the notebook empty state were verified in the simulator. The update was installed on the paired iPhone. Simulator visual review completed for ready, setup, support, and notebook screens; expanding help and navigating to diagnostics were verified. Live lifting, populated notebook layout, interrupted-session layout, large accessibility text, and dark-mode review remain device/design follow-ups.

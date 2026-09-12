# GUI requests

Reference: `Workout timer app fix.zip` from Claude Design (`LiftPod.dc.html` and `SupportScreen.dc.html`).

Current scope: native iPhone workout tracking, manual exercise selection, explicit set boundaries, qualified slowdown coaching, and deterministic next-set guidance. K2 Horizon remains excluded. This file tracks design work; it does not authorize implementing deferred features.

## Implemented adaptations

- Both interfaces default to Adaptive-axis V6 curl detection; older comparison profiles remain selectable in the developer lab.
- Tap the top-left liftpod wordmark to switch between workout and developer interfaces; tap it again to return. The capture and workout models stay alive across switches.
- Fixed readiness flicker caused by comparing fresh callbacks with an older UI timer tick. Live motion expires after 0.5 seconds without samples; left/unknown source status is separate from the right-side curl requirement.
- Review setup remains enabled while waiting for motion. Only starting a workout requires a live right-side stream and confirmed setup.
- A completed set opens a compact result and next-set decision. Review remains optional, with editable weight and reps plus optional RIR; only confirmed sets enter permanent workout history.
- The notebook icon opens confirmed workouts grouped by day, with set count and daily volume.
- Setup can offer a rounded next-load estimate from up to eight eligible confirmed sets. It shows low, medium, or high confidence; the user must explicitly choose it and can edit it afterward.
- White/blue visual language, translucent controls, concentric rep halo, lowercase wordmark, and timeline summary translated into SwiftUI.
- Setup stays in a sheet so exercise, load, rep range, and mount confirmation remain available without crowding the ready screen. Training goal is hidden until it affects the decision policy.
- Live status distinguishes live right-AirPod motion from waiting/disconnected states. A simulated Bluetooth connection never enables a workout.
- Added preparation, finalizing, empty workout, interruption, and between-set states missing from the main mockup. The user explicitly starts and ends each set.
- The between-set timer shows a simple research-based rest suggestion after the completed set's reps and RIR are confirmed. It never blocks the next set.
- Rep pulse follows actual completed reps and honors Reduce Motion. No synthetic rep generation or automatic exercise switching.
- Workout timer continues through rest while retaining sensor-source time for deterministic tests; active rep time sums accepted rep durations.
- Live coaching shows one qualified relative slowdown state and its reason. It never exposes absolute speed or changes the committed rep count.
- Per-set results add actual load, rep target, slowdown evidence when valid, and one constrained next-set decision.
- Support topics open real help text, search works, and the bottom action opens existing diagnostics.

## Open requests

| Priority | Request | Reason / acceptance criterion |
| --- | --- | --- |
| P1 | Validate AirPods 4 source selection on device with both earbuds connected and Automatic Ear Detection off. | Confirm left/right status reflects diagnostics and the button stays stable; test right-only mounting. |
| P1 | Supply a mount illustration or photo for the tested right-AirPod curl orientation. | The reference dumbbell symbol cannot teach correct placement. Add artwork to setup/help once supplied. |
| P1 | Review live counting and timer legibility at lifting distance on a real iPhone. | Simulator review cannot validate visibility during exercise. Confirm rep halo, elapsed time, and countdown remain readable. |
| P1 | Validate curl and lateral-raise profile switching on device. | Manual selection is enabled for both bundled profiles; profiles alone do not provide automatic classification. |
| P2 | Validate relative slowdown thresholds with physical trials. | The UI exposes only qualified slowdown relative to the first three eligible reps. Absolute velocity remains hidden. |
| P2 | Decide whether the main timer should mean elapsed workout time or active rep time. | Current top timer is elapsed source time; summary separately labels active rep time. The export conflates these. |
| P2 | Review dark appearance and accessibility text sizes on device. | Native semantic colors support dark mode; the main export provides a light-only reference. Confirm halo contrast and long-label wrapping. |
| P2 | Specify a reconnection experience if resuming the same workout is wanted. | Current engine ends the interrupted workout and preserves reps. The export's reconnect-and-resume animation does not match that lifecycle. |

## Reference elements intentionally omitted

- “Rhythm: Steady”: hardcoded in the export, with no measured rhythm contract.
- Expert chat, phone support, and “Avg. wait 2 min”: no service, phone number, or availability source exists. Replaced by diagnostics.
- Subscriptions, billing, refunds, firmware updates, and LiftPod Plus: no corresponding product services exist.
- Simulate controls and fabricated summary fallback values: design-preview tools, not workout data.
- Automatic load changes and K2: outside current scope. Next-set advice is informational and never edits the load without the user's action.

## Verification

The focused manual-workout tests cover explicit boundaries, coaching validity, constrained next-set advice, interruption retention, and recording finalization. Live lifting, populated notebook layout, interrupted-session layout, large accessibility text, and dark-mode review remain device/design follow-ups.

# GUI requests

Reference: `Workout timer app fix.zip` from Claude Design (`LiftPod.dc.html` and `SupportScreen.dc.html`).

Current scope: native iPhone workout tracking, manual exercise selection, explicit set boundaries, qualified slowdown coaching, and deterministic next-set guidance. K2 Horizon remains excluded. This file tracks design work; it does not authorize implementing deferred features.

## Implemented adaptations

- Developer home exports the latest workout set as a complete ZIP; the signal lab exports its completed set as a ZIP. Raw recording export saves CSV through Files and reports failures.
- Removed confidence labels from workout rep/load recommendations and automatic RIR text, retaining measured inputs and model details.

- Restored the Claude reference’s white workout appearance, faint blue background glow, and translucent white cards while retaining the added controls. The top-left name still switches to the developer interface.
- Removed the mount-confirmation checkbox and its start gate. Live right-AirPod motion is still required; mounting guidance remains informational.

- Both interfaces default to generic movement counting for curls, lateral raises, overhead press, and future exercise selections. Specialized comparison profiles remain selectable in the developer lab.
- The main workout keeps detector choices out of setup. Bundled Adaptive V6 curl and Gravity Tilt lateral-raise profiles remain available for comparison in the developer lab.
- Tap the top-left liftpod wordmark to switch between workout and developer interfaces; tap it again to return. The capture and workout models stay alive across switches.
- Fixed readiness flicker caused by comparing fresh callbacks with an older UI timer tick. Live motion expires after 0.5 seconds without samples; left/unknown source status is separate from the right-side curl requirement.
- Review setup remains enabled while waiting for motion. Only starting a workout requires a live right-side stream and confirmed setup.
- A completed set opens a compact result and next-set decision. Review remains optional, with editable weight and reps plus optional RIR; only confirmed sets enter permanent workout history.
- The notebook icon opens confirmed workouts grouped by day, with set count and daily volume.
- The between-set screen and setup can show an optimized next set: an available weight, rep target, target RIR, confidence, and measured reason. The bounded controller changes at most one 5 lb equipment step and the user must explicitly apply it.
- The rest suggestion now adapts to finalized within-set rep-speed loss and to a 20% or larger drop in estimated rep capacity across consecutive same-load sets. The UI names the signal that raised the target, while the next set remains available at any time.
- Target RIR and the user's available 2.5, 5, or 10 lb equipment step are explicit inputs. Goal presets populate coherent rep-range and RIR targets, and recommendation reasons quote the actual previous-set result.
- White/blue visual language, translucent controls, concentric rep halo, lowercase wordmark, and timeline summary translated into SwiftUI.
- Setup stays in a sheet so exercise, load, goal, rep range, target RIR, equipment increment, and mount confirmation remain available without crowding the ready screen.
- Live status distinguishes live right-AirPod motion from waiting/disconnected states. A simulated Bluetooth connection never enables a workout.
- Added preparation, finalizing, empty workout, interruption, and between-set states missing from the main mockup. The user explicitly starts and ends each set.
- The between-set timer shows a simple research-based rest suggestion after the completed set's reps and RIR are confirmed. It never blocks the next set.
- Set review pre-fills automatic RIR when at least three finalized rep-speed measurements, including the final rep, pass quality checks. It shows speed loss, model type, confidence, and suggested rest; the user can correct it.
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
| P1 | Validate generic counting for each exercise and mounting setup on device. | Curl, lateral raise, and overhead press are enabled through one learned movement detector; verify counts and speed quality with real sets. |
| P2 | Validate relative slowdown thresholds with physical trials. | The UI exposes only qualified relative slowdown evidence. Absolute velocity remains hidden. |
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

Automated coverage includes explicit manual boundaries, generic workout recording and replay, coaching fallback, confirmed-history persistence, legacy migration, adaptive rest calculations, and bounded optimizer behavior. The ready screen was verified in the simulator. Live lifting, populated notebook layout, interrupted-session layout, large accessibility text, and dark-mode review remain device/design follow-ups.

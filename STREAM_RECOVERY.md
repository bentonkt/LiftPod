# Live stream handling and set recovery

## Findings

The live set engine treated every resampler discontinuity as fatal `invalidInput`. A single source bracket over 60 ms therefore ended a set. Separately, the Signal Lab fed detection from SwiftUI `onChange` of a latest-value display property, which cannot guarantee delivery of each sensor callback. Resampling the entire set for each callback also made cumulative processing quadratic in capture length. These are reproducible code paths, not confirmation of the exact cause of an unrecorded phone failure.

Additional presentation issues were a V4 default on the V6 screen, mutable setup controls during an active set, and replay verification being invoked repeatedly on completed-set updates.

## Current behavior

- The capture stream awaits one analysis consumer for every provider event, in order. SwiftUI publication no longer transports detector samples.
- `incremental-stream-v1` retains one source bracket, a fixed session anchor, a 50 Hz grid index, and a discontinuity epoch. Work and resampler storage do not grow with set duration.
- Brackets through 60 ms interpolate. Larger gaps never interpolate across the missing interval.
- Source gaps, finite invalid quaternion/gravity frames, implausible attitude jumps, and observed receipt pauses clear the active candidate and passive speed integration. They preserve committed events, the set, and the prepared reference when already active.
- Recovery requires 250 ms of continuous valid samples. Further failures restart this dwell. The detector must then independently qualify its starting position; recovery does not manufacture a rep.
- Preparation discontinuities clear reference acquisition rather than combining separated quiet windows.
- End Set still suppresses all new departures and retains its existing drain. A recovery timer cannot finish a rep.
- Wrong bud, disconnect, backgrounding, backward source clocks, non-finite input, and recording failures still interrupt the set. The UI now records and presents the particular reason.
- Adaptive-axis V6 is the default. Setup controls are disabled while a set is running. Other detector profiles remain selectable before Start Set.
- Completed-set replay runs once per exported bundle, off the live consumer path.

The stream version is recorded separately from detector profiles and speed configuration. New replay regenerates incremental uniform samples and metrics, checks recovery state, and rejects committed reps spanning invalid intervals. Existing archives without the stream version retain their batch-verification path. No rep thresholds or motion-axis math changed.

## Verification and remaining limits

Regressions cover clean batch/stream agreement, quaternion sign equivalence, gap boundaries, preserved counts/reference, repeated-gap recovery, no stitched reps, finalization, receipt pauses, clock resets, recovered-set replay, all-sample delivery without UI redraws, and a synthetic five-minute stream. Existing detector and passive-metrics tests remain required.

Test on the phone with a normal set, then a longer set while scrolling the screen. A recoverable failure should display Recovering, retain the count, and allow later complete reps after returning to the start. Export a failing set to identify its actual source/receipt timing and quality reason.

This does not prove real-device timing or sensor accuracy. Completely silent delivery is still surfaced by provider disconnect/error events or the next receipt; a separately recorded watchdog is not implemented here. Raw recording and the provider stream currently retain unbounded buffers, so unusually long sessions still need a bounded recording/backpressure design. Neither limitation is hidden by relaxing rep validation.

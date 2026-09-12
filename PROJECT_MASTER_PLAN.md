> **Current scope override (2026-09-11):** The user has removed K2 Horizon from the current project. Ignore all K2 integration, sponsor, model-deployment, and K2 acceptance requirements below. Active coaching and load recommendations are deferred. The current implementation scope is automatic set completion after 12 seconds without a completed rep. The original document is retained for historical context.

# LiftPod master product and build plan

Status: proposed source of truth for product scope and build order  
Prepared: 2026-09-11  
Primary target: a reliable hackathon demonstration with a credible path to a real product

## Executive decision

LiftPod should be presented as:

> **An AirPod-powered adaptive strength coach that understands each set, detects when rep quality changes, and uses K2 Horizon to plan what the athlete should do next.**

The core product is the AirPod attached to the dumbbell. The phone is the display and primary compute device. Exercise detection, rep counting, and movement metrics are the measurement layer; the product story is the closed loop from those measurements to a grounded training decision. The minimum complete experience is:

```text
Attach AirPod to dumbbell
  -> verify motion signal
  -> choose a goal and target rep range
  -> start workout
  -> recognize the exercise automatically
  -> count reps and sets
  -> compare each rep with the current-set baseline
  -> recommend Keep going or Target reached
  -> use K2 Horizon to plan and explain the next set
  -> save the measurements, decisions, and workout summary
```

Phone-plus-Apple-Watch full-body pose is an optional showcase mode, not part of the critical path. It adds setup, calibration, networking, and another wearable; making it mandatory would weaken the simple “turn an ordinary dumbbell into a smart dumbbell” story.

## Product principles

1. **The weight is instrumented, not the person.** The AirPod-on-dumbbell interaction is the differentiator.
2. **Close the loop from sensing to action.** Tracking explains what happened; LiftPod must also make one grounded, useful training recommendation.
3. **Zero exercise selection supports the hero behavior.** A user should be able to switch between supported exercises without touching the phone.
4. **Reliability beats breadth.** Three exercises that work repeatedly are better than ten unreliable labels.
5. **Every live result must be replayable.** Raw motion, predictions, state changes, rep events, K2 requests, and coaching decisions are recorded so failures can be reproduced without hardware.
6. **Separate sensing, inference, and product decisions.** A classifier probability is not automatically a displayed exercise, rep, set, or coaching action.
7. **Ground K2 in verified facts.** K2 reasons over a structured set summary and a finite action set; it never counts raw samples or invents sensor measurements.
8. **Do not overclaim biomechanics.** Tempo, relative slowdown, and consistency can be useful product metrics. Exact distance, velocity, RIR, form, or injury-risk claims require separate validation.
9. **The demo must degrade gracefully.** Stale or disconnected motion produces a clear unavailable state, never confident-looking fabricated results or advice.
10. **Manual controls are a development adapter, not the product architecture.** Manual exercise and set controls must drive the same stable-exercise and workout-state interfaces later driven by the classifier, so validation work is retained when automation is enabled.

## What the hackathon project should contain

### Required core

- a stable, repeatable AirPod-to-dumbbell mount;
- AirPod connection and motion-quality status;
- a clear start/end workout flow;
- automatic recognition of bicep curl, lateral raise, overhead press, and other/idle;
- stable switching between supported exercises;
- exercise-aware rep counting;
- automatic set boundaries while a workout remains active;
- a selectable training goal and target rep range;
- manual exercise and set controls in developer mode for data collection, isolation testing, and fallback;
- rep duration and tempo;
- a relative within-set baseline built from the first valid reps;
- a smoothed `steady`, `approachingTarget`, `targetReached`, or `degraded` quality state;
- a live `Keep going` or `Target reached` recommendation with the measured reason;
- a structured set summary passed to K2 Horizon;
- a schema-validated K2 next-set action and grounded explanation;
- a deterministic coaching fallback for K2 failure or timeout;
- a live screen showing exercise, reps, quality state, recommendation, and signal state;
- a session summary with exercise, sets, reps, timing, quality trend, and next-set plan;
- raw-data recording and deterministic replay;
- a diagnostic screen for the team.

### Valuable stretch features

- motion-consistency score relative to the user's prior reps in the same set;
- range-of-motion proxy, explicitly labeled as relative rather than degrees or centimetres;
- concentric/eccentric duration;
- a validated relative speed or explosiveness indicator;
- local workout history;
- audio or haptic rep feedback;
- guided mount/calibration illustrations;
- prerecorded replay mode for explaining the system when hardware is unavailable;
- conversational “Why?” follow-up grounded in the saved set summary;
- K2-generated rest or volume adjustment in addition to load adjustment.

### Optional showcase

- phone-plus-Watch MobilePoser skeleton;
- synchronized overlay of the independent dumbbell rep event on the skeleton;
- on-device pose inference if the live Mac path is already reliable.

The pose showcase must use a separate pipeline. A dumbbell-mounted AirPod is not a valid MobilePoser head sensor and must never be passed into that model's head slot.

### Optimization-track positioning

If LiftPod is submitted to the Optimization track, the product must close the loop from sensing to action. Exercise recognition, counting, and metrics enable the optimization; they are not the optimization result by themselves.

The judge-facing loop is:

```text
measure each rep
  -> compare speed, timing, and consistency with the set baseline
  -> estimate a relative fatigue/quality zone
  -> recommend keep going, end the set, or adjust the next set
```

Promote relative fatigue/quality plus one live continue/stop recommendation into the hero path. Build it after reliable rep segmentation and before pose, history, exact RIR, or additional exercises. Use the detailed scope and pitch in [`OPTIMIZATION_TRACK_PITCH.md`](./OPTIMIZATION_TRACK_PITCH.md).

### IFM K2 Horizon sponsor integration

LiftPod can pursue the IFM sponsor prize without changing its main Optimization-track story. K2 Horizon should receive a verified structured set summary and select a constrained next-set action based on the user's goal, target range, fatigue trend, and prior sets. It must not classify raw motion or count repetitions.

Add this only after set summaries and relative fatigue metrics work. Validate the structured response, restrict it to allowed actions, and retain a deterministic fallback. See [`IFM_K2_HORIZON_SPONSOR_PLAN.md`](./IFM_K2_HORIZON_SPONSOR_PLAN.md).

### Explicit non-goals for the hackathon

- recognizing every gym exercise;
- exact free-space dumbbell position from inertial double integration;
- medically meaningful form or injury-prevention claims;
- exact RIR from a generic population equation;
- a polished account, cloud, social, or subscription system;
- HealthKit integration unless the core demo is already frozen;
- dual-dumbbell synchronization;
- a production-general mount that tolerates arbitrary AirPod placement;
- full-body pose as a dependency for exercise recognition or rep counting.

## The hero demo

The demo should make one idea obvious in under a minute: **LiftPod sees how the weight moved and changes what the athlete should do next.**

1. Show an ordinary dumbbell and attach the AirPod.
2. Open LiftPod and show that the motion signal is live.
3. Choose a goal and target rep range, then start without selecting an exercise.
4. Perform several consistent curls. LiftPod identifies the exercise, counts reps, and establishes a relative baseline.
5. Deliberately slow the final repetitions. Show the quality state move from `Steady` to `Target reached` and the live recommendation change.
6. End the set. Show the verified `SetSummary` sent to K2 Horizon.
7. Show **K2 Adaptive Plan** select an allowed next-set action and explain it using the recorded slowdown, consistency, target range, and prior-set context.
8. If time permits, ask “Why?” or switch briefly to a second exercise to show that the same loop is exercise-aware.
9. Briefly show replay/diagnostics to establish that the sensor inference and K2 decision are genuine and recorded.

If pose is ready, show it only after this sequence as a separate “richer coaching view.” The core pitch must already have landed.

## System architecture

```text
                         CORE PRODUCT

AirPod on dumbbell
  -> HeadphoneMotionService
  -> stream validation + raw recorder
  -> shared resampling/feature layer
       +-> exercise predictor -> prediction smoother -> stable exercise
       +-> rep signal processor <---------------------- stable exercise
                                     |
                                     v
                              workout state machine
                           rep -> set -> session events
                                     |
                   +-----------------+----------------+
                   v                                  v
       relative quality state                  verified SetSummary
       + live stop/continue                           |
          recommendation                              v
                                             allowed-action policy
                                                      |
                                                      v
                                            K2 Horizon set planner
                                                      |
                                                      v
                                           schema validator/fallback
                                                      |
                                  +-------------------+----------------+
                                  v                                    v
                         live workout UI                       session summary

                    OPTIONAL, INDEPENDENT SHOWCASE

Apple Watch + iPhone motion -> MobilePoser -> skeleton visualization
                                                ^
                                                |
                               timestamped rep event overlay only
```

### Architectural boundaries

- The motion service owns sensor lifecycle and raw samples, not workout meaning.
- The exercise predictor owns probabilities, not the displayed label.
- The decision smoother owns entry, exit, switching, and unknown behavior.
- The rep processor owns phase transitions and completed-rep events.
- The workout state machine owns sets, rest periods, summaries, and UI-facing state.
- The quality engine owns the within-set baseline, relative feature changes, and smoothed target state.
- The allowed-action policy converts verified facts and product constraints into the finite actions K2 may choose.
- K2 Horizon owns contextual next-set selection and explanation, not measurement or safety claims.
- The K2 response validator owns schema enforcement, action bounds, timeout handling, and deterministic fallback.
- The recorder observes all layers and must not change their behavior.
- The UI renders state and sends explicit user intent; it does not calculate reps.
- MobilePoser consumes phone/Watch motion independently and may receive timestamped workout events for display only.

## Canonical product events and records

Define these early so workstreams can progress independently:

```text
RawDumbbellMotionSample
  timestamp, acceleration, rotation rate, gravity, attitude, stream quality

ExercisePrediction
  effective timestamp, probability per label, model ID, input quality

StableExerciseState
  label/unknown, enteredAt, confidence summary, reason

RepEvent
  exercise, rep index, startedAt, completedAt, phase durations, relative metrics, quality flags

RepQualityState
  set ID, baseline readiness, relative slowdown, consistency, target state, evidence

SetSummary
  exercise, load, goal, target range, start/end, reps, average tempo,
  slowdown trend, consistency, target result, prior-set context, validity flags

CoachingDecision
  set ID, provider/model, allowed actions, selected action, next target,
  reason codes, display message, latency, validation/fallback status

WorkoutSessionSummary
  session ID, start/end, sets, decisions, totals, sensor/model/planner versions
```

All events use the same monotonic iPhone session timeline. Preserve both source time and display time when latency matters.

## Exercise-detection integration contract

The exercise pipeline should remain an adapter behind a narrow interface rather than owning UI, workout-state, quality, or coaching logic.

```swift
protocol ExercisePredicting: Sendable {
    var modelMetadata: ExerciseModelMetadata { get }
    func predict(window: ExerciseInputWindow) async throws -> ExercisePrediction
}
```

Required handoff artifacts:

- the Core ML model or selected model artifact;
- exact input schema, feature order, rate, window length, and normalization contract;
- stable label identifiers;
- model/dataset version metadata;
- one or more frozen input windows with expected outputs;
- held-out-participant metrics and confusion matrix;
- scripted `other` false-activation results;
- measured inference cadence and effective timestamp semantics;
- clear stale, warm-up, invalid-input, and error behavior.

The master app owns smoothing thresholds and displayed state unless the model package explicitly includes a versioned, tested decision policy. Raw probabilities should always remain recordable.

Add a `ManualExercisePredictor` and `ReplayExercisePredictor` behind the same interface. Manual mode is an engineering fallback for building and testing rep logic; it is not the hero demo.

Manual selection and the automatic classifier must both ultimately publish the same versioned `StableExerciseState` contract. Rep detectors and the workout state machine must not know which producer supplied that state. This permits development in three deliberate stages:

1. select an exercise and explicitly start/end a set while validating signal processing;
2. select an exercise only when it changes, while rep events start sets and inactivity ends them automatically;
3. replace manual exercise selection with stable classifier output for the touch-free workout.

This staging isolates classifier, rep-detector, and set-boundary failures without creating throwaway logic. Record all measured sample-rate, window-shape, normalization, label, and model-version constants in repository code and model metadata so the implementation is self-contained.

## Rep, set, and metric strategy

### Rep counting

Rep counting should be exercise-specific signal processing, not another large general model for the MVP.

1. Select a stable one-dimensional phase signal for each exercise from acceleration, gravity/orientation, or angular velocity.
2. Filter it and use hysteresis to detect concentric, apex, eccentric, and completed-cycle transitions.
3. Tune thresholds from recorded sessions, not a single live trial.
4. Count only complete cycles while the stable exercise state matches.
5. Attach quality flags when samples are stale, the exercise switches mid-rep, or phase duration is implausible.

Build one generic phase-state-machine abstraction with per-exercise configurations. Start with curl because it should have the clearest rotational cycle, then overhead press, then lateral raise.

The product must not require a manual calibration gesture at the start of every workout. Where a profile needs a neutral reference, acquire it implicitly from a short low-motion dwell in a broad admissible start region, freeze it during an active rep, and adapt it only at confirmed endpoints within a strict trained bound. Continue buffering recent raw samples so a reference acquired late can be used to recover the first valid rep. If no trustworthy reference is available, show `Detecting…` rather than guessing. Acceleration/gyro biphasic profiles may operate without an orientation reference but still require automatic noise-baseline estimation.

### Set boundaries

The workout engine runs continuously from `Start Workout` until `End Workout`; the production flow has no required per-set button. Initial set logic:

- start a set on the first completed rep after a stable exercise entry;
- keep a set open through short pauses;
- end retrospectively after a tuned period with no valid rep, when a different positive exercise becomes stable, or when the workout ends;
- never merge reps from different exercises into one set;
- never create an empty set from pickup, carry, grip adjustment, or classifier activity alone;
- mark an open set interrupted on a disconnect or invalid source interval, and never allow a rep to span that interval;
- retain the count through temporary `other`, unknown, or stale states unless a new set boundary is actually confirmed;
- allow explicit Start Set and End Set controls in developer mode, with End Set available as a non-required fallback outside the hero flow.

Set completion necessarily has a short decision delay: until the inactivity threshold expires, the engine cannot distinguish a finished set from a long between-rep pause. Freeze a product rule for this ambiguity, validate it against deliberate pauses, and keep the live rep count immediate while the set remains provisionally open.

### Metrics to show

Ship first:

- rep count;
- total rep duration;
- concentric and eccentric duration if phase detection supports them;
- within-set tempo consistency;
- objective rep slowdown/fatigue trend;
- current relative quality state and the evidence that changed it;
- live `Keep going` or `Target reached` recommendation;
- set duration and rest duration.

Ship only after validation:

- relative motion amplitude/range proxy;
- relative explosiveness or speed score;
- velocity estimated with per-rep drift reset and a visible experimental label.
- personalized RIR bands after exercise-specific calibration and later-session validation.

Do not show absolute centimetres, metres per second, joint angles, or form scores merely because the pipeline can emit a number.

## User experience

### 1. Ready screen

- AirPod connected/unavailable;
- motion stream live/stale;
- mount instruction;
- goal and target rep-range selection;
- Start Workout button disabled until the stream is usable;
- compact diagnostics disclosure.

### 2. Live workout screen

- large stable exercise label or “Detecting…” / “No exercise detected”;
- large rep count;
- relative quality state and baseline readiness;
- prominent `Keep going` or `Target reached` recommendation;
- the measured reason for the current recommendation;
- current phase or a simple motion pulse;
- small set number and elapsed time;
- unobtrusive connection/quality indicator;
- End Workout and optional End Set controls;
- debug probability panel plus manual exercise and set controls behind a developer toggle, not in the judge-facing default.

### 3. Session summary

- chronological sets grouped by exercise;
- reps per set;
- average tempo and consistency;
- relative slowdown/quality trend;
- **K2 Adaptive Plan** action and grounded explanation;
- total active and rest time;
- Share/export diagnostics only in developer mode.

### 4. Diagnostics and replay

- delivered sensor rate and largest timestamp gap;
- latest raw channels and magnitudes;
- model probabilities and stable-state reason;
- rep-phase signal and thresholds;
- relative-quality features, baseline, thresholds, and state changes;
- exact structured K2 request, response, model, latency, and fallback reason;
- active model, dataset, feature schema, and build versions;
- select a recorded session and replay it deterministically.

## Build order

The order below is dependency-based. Do not advance because a screen looks finished; advance when its exit gate passes.

### Phase 0 — freeze the product contract

- adopt the adaptive-coach positioning and hero demo above;
- freeze the three positive exercises and `other` for the hackathon;
- select one AirPod, one phone, one dumbbell/mount geometry, and the intended demo arm;
- freeze the supported goals, target rep-range behavior, K2 allowed actions, and claim language;
- define the canonical event types, session timeline, `SetSummary`, and `CoachingDecision` schemas;
- assign one owner to each workstream and one person responsible for integration.

Exit gate: the team can state the same one-sentence pitch, demo sequence, labels, and data contracts.

### Phase 1 — prove the physical and sensor foundation

- finalize a repeatable, keyed mount that cannot rotate during a set;
- prove connection, motion delivery, timestamps, and five-minute stability while mounted;
- expose rate, gaps, staleness, and disconnects;
- verify a cold-start setup flow on the intended demo hardware.

Exit gate: three consecutive mounted five-minute captures are usable, and reconnecting does not require code changes or reinstalling the app.

### Phase 2 — make everything recordable and replayable

- finish the versioned raw-data and recording-metadata schema;
- record raw motion plus derived predictions and workout events;
- add deterministic file replay through the same consumers as live samples;
- create frozen fixtures and a short known-good demo recording;
- add export/share for team debugging.

Exit gate: a live session and its replay produce the same model inputs, stable labels, rep events, and summaries within defined tolerances.

### Phase 3 — build the workout engine independently of ML

- implement the exercise-predictor protocol;
- use manual and replay predictors to build stable-exercise, rep, set, and session state machines;
- first validate with explicit exercise selection and Start Set/End Set controls;
- then remove the per-set requirement: open on the first authorized rep and close after validated inactivity while exercise selection remains manual;
- implement curl rep counting first, then overhead press, then lateral raise;
- add unit tests for transitions, partial reps, long between-rep pauses, automatic set timeouts, exercise switches, stale data, and disconnects.

Exit gate: prerecorded fixtures create correct reps and automatic set boundaries without a live classifier; manual exercise state and replay exercise state produce equivalent downstream events.

### Phase 4 — integrate automatic exercise detection

- integrate the repository's exercise-prediction artifact behind `ExercisePredicting`;
- verify preprocessing fixtures across its training runtime and Swift;
- add live inference without putting model work on the main actor;
- tune entry, exit, switching, and unknown behavior from validation recordings;
- feed only the stable exercise state into the rep processor.
- remove manual exercise selection from the default workout path while retaining it in developer mode.

Exit gate: one Start Workout action followed by the supported exercise sequence produces the correct exercise labels, reps, and set boundaries without per-exercise or per-set input, with documented live, held-out-person, and `other` false-activation results.

### Phase 5 — finish the core product UI

- connect the ready, live, summary, diagnostics, and replay screens to the workout engine;
- make warm-up, uncertainty, staleness, disconnect, and recovery visible;
- reserve the primary live coaching area and K2 Adaptive Plan summary state using fixture data;
- add accessible sizing/contrast and keep the live screen readable from lifting distance;
- remove engineering controls from the default demo path.

Exit gate: someone who did not build the app can attach the sensor, start, perform the scripted workout, and understand the summary without coaching.

### Phase 6 — harden rep quality and metrics

- validate rep counts across participants, speeds, weights, and supported exercises;
- tune phase boundaries and set timeout;
- add tempo, phase timing, relative slowdown, and within-set consistency;
- build the first-valid-reps baseline and suppress it when there is insufficient valid data;
- evaluate any speed/range proxy against video or another reference before displaying it as quantitative.

Exit gate: at least 95% of complete scripted reps are counted, no partial movement is counted as two reps, reported metrics have documented meanings, and deliberate slowdown produces a repeatable relative change without claiming exact RIR.

### Phase 7 — close the deterministic optimization loop

- define target zones for the supported hackathon goals;
- smooth rep-level evidence into `steady`, `approachingTarget`, `targetReached`, and `degraded` states;
- emit the live `Keep going` or `Target reached` recommendation with reason codes;
- compute the finite allowed next-set actions from target result, rep range, signal validity, and available weights;
- replay frozen sets through the same policy and record every state transition.

Exit gate: a scripted steady-then-slow set visibly changes the live recommendation at the intended point, invalid data suppresses coaching, and replay produces the same allowed actions.

### Phase 8 — integrate IFM K2 Horizon

- implement a K2 client against a frozen `SetSummary` fixture before using live data;
- prefer the sponsor-provided endpoint and recommended model; otherwise use a K2 model hosted on the demo Mac;
- require schema-valid structured output restricted to the supplied allowed actions;
- show the selected action, reason codes, and measurement-grounded explanation as **K2 Adaptive Plan**;
- log request, response, model ID, latency, validation result, and fallback reason;
- implement timeout, invalid-output, low-confidence, and offline fallbacks;
- connect the live `SetSummary` only after all fixture cases pass.

Exit gate: K2 returns a valid action for every frozen valid fixture, cannot select a disallowed action, produces no advice for invalid fixtures, and the app remains usable when K2 is unavailable.

### Phase 9 — freeze and rehearse the demo

- run the exact hero sequence on the intended hardware at least five times;
- test cold launch, Bluetooth reconnection, low-confidence transitions, accidental handling, K2 timeout, and malformed K2 output;
- freeze the mount, exercise model, quality thresholds, K2 prompt/schema/model, app build, phone orientation, and demo dumbbell;
- prepare a truthful prerecorded replay as a diagnostic fallback;
- prepare one slide explaining sensor -> verified metrics -> allowed actions -> K2 plan and one slide with held-out results.

Exit gate: five consecutive successful rehearsals, including at least one cold start, with no developer intervention.

### Phase 10 — add pose only after the core is frozen

- first prove phone-plus-Watch pose independently;
- overlay timestamped rep/set events without changing the dumbbell pipeline;
- present it as an optional richer visualization, not the source of the dumbbell results.

Exit gate: pose can be disabled entirely without affecting exercise recognition, rep counting, the live workout, or the summary.

## Parallel workstreams

| Workstream | Primary output | Depends on | Can begin |
|---|---|---|---|
| Hardware and sensor | fixed mount, reliable stream, quality diagnostics | intended hardware | immediately |
| Recording and replay | versioned sessions, fixtures, deterministic replay | raw sample type | immediately |
| Exercise detection | stable model artifact and integration fixtures | usable recordings | after first pilot capture |
| Rep and workout engine | rep/set/session events | replay samples; manual labels initially | immediately after event contracts |
| Quality and optimization | relative baseline, target state, allowed-action policy | valid rep events and set summaries | after curl rep segmentation works |
| IFM K2 integration | validated next-set decision and explanation | frozen `SetSummary` and allowed actions | with fixtures before live integration |
| Product UI | ready/live/summary/diagnostics views | mock workout state first | immediately after state contract |
| Demo validation | scripts, metrics, failure corpus, rehearsals | integrated core | continuously, then final freeze |
| MobilePoser showcase | independent skeleton and event overlay | frozen core and spare capacity | last |

Integration should happen daily through fixtures, not as one final merge. Each workstream must provide a runnable example or replay, not only source code.

## Priority and cut order

When time runs short, cut from the bottom upward.

| Priority | Keep/cut rule | Features |
|---|---|---|
| P0 | Never cut | mount, live AirPod motion, recording/replay, supported exercises + other, stable label, rep count, automatic set boundaries, relative baseline, live target state, stop/continue recommendation, usable UI, graceful disconnect |
| P0-IFM | Required for the sponsor submission | real K2 Horizon call, structured set input, constrained next-set action, grounded explanation, schema validation, deterministic fallback |
| P1 | Keep if core is stable | three-exercise breadth, tempo/phase detail, full diagnostics, scripted held-out evaluation, conversational “Why?” |
| P2 | Cut before risking reliability | range/explosiveness proxy, history, sounds/haptics, polished onboarding, additional K2 action types |
| P3 | First to cut | MobilePoser, on-device pose conversion, HealthKit, cloud/accounts, extra exercises, dual dumbbells |

Do not respond to a weak P0 demo by adding a P2 or P3 feature. Improve the mount, negative data, state transitions, and recovery behavior first.

## Project-wide acceptance criteria

The hackathon build is ready when all of these are true:

- setup from cold launch to a live signal is repeatable on the demo hardware;
- classifier results include documented held-out-participant performance, a confusion matrix, and scripted `other` false-activation checks;
- at least 95% of complete reps in the scripted demo are counted;
- switching exercises does not merge sets or count a transition as a rep;
- after one Start Workout action, sets open on the first authorized rep and close on validated inactivity, exercise switch, or End Workout without requiring a set button;
- the displayed label does not flicker on one weak prediction;
- the first valid reps establish a stable relative baseline and deliberate slowdown changes the target state repeatably;
- uncertain exercise, stale motion, insufficient baseline data, or an interrupted set suppresses coaching rather than generating advice;
- the live recommendation exposes measurement-grounded reason codes;
- K2 receives only the recorded structured `SetSummary` and supplied allowed actions;
- every accepted K2 action passes schema and bounds validation, while invalid output or timeout uses the deterministic fallback;
- the K2 Adaptive Plan shown in the hero demo is generated by a real K2 Horizon invocation and is recorded with model ID and latency;
- the app clearly reports warm-up, uncertainty, stale data, and disconnects;
- the full hero sequence succeeds five consecutive times;
- raw input, derived events, K2 exchanges, and coaching decisions are saved and replayable;
- the summary agrees with the observed demo workout;
- no screen or spoken pitch claims unvalidated absolute motion, exact RIR, injury prevention, or form accuracy;
- the AirPod-only core works with the pose subsystem disabled.

## Post-hackathon roadmap

### Product validation

- test whether users value automatic logging, rep metrics, or coaching most;
- measure mount convenience and willingness to attach an AirPod to a weight;
- validate more people, dumbbell shapes, weights, grips, and left/right use;
- determine whether per-user calibration materially improves recognition.

### Capability expansion

- add exercises one confusion cluster at a time;
- add personalized thresholds or lightweight fine-tuning;
- support more mount geometries with explicit calibration/versioning;
- add dual-dumbbell and bilateral-consistency experiments;
- validate velocity/range estimates against external ground truth;
- add local history and HealthKit only after measurement meaning is stable.

### Productization

- design a secure, durable mount with consistent sensor geometry;
- establish supported AirPod models and OS behavior;
- handle battery, disconnect, privacy, data retention, and firmware/OS regressions;
- replace noncommercial research dependencies before any commercial use;
- run broader evaluation before making coaching, safety, or performance claims.

## Repository-local planning documents

- [`OPTIMIZATION_TRACK_PITCH.md`](./OPTIMIZATION_TRACK_PITCH.md): optimization objective, closed-loop MVP, judge-facing demo, claim boundaries, and submission language.
- [`IFM_K2_HORIZON_SPONSOR_PLAN.md`](./IFM_K2_HORIZON_SPONSOR_PLAN.md): grounded K2 set-planning role, schemas, guardrails, deployment choices, and sponsor demo.

This master plan owns product priority, integration order, and acceptance gates. The two focused documents above expand the competition positioning and K2 integration while remaining inside this repository.

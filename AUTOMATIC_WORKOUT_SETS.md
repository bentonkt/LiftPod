# Automatic sets and rest: revised design after adversarial review

Status: design only. This revision supersedes the original proposal's single
rest/set timer, provisional 1/3 display, and immediate sealing rules. No app code
has changed. Scope remains a user-armed Auto workout using generic motion;
manual exercise-profile and generic modes remain available.

## Review verdict

Keep continuous workout capture, the generic pattern engine, a separate pure set
coordinator, passive metrics, and replay. Strengthen the boundary and evidence
contracts before implementation. The recommended approach is **continuous cycle
discovery with a bounded delay for resolving work and set boundaries**.

This is the best-supported engineering choice for the current code and available
data, not an experimentally established best detector. Whole-workout captures
and a phone-lock feasibility check are prerequisites to a broad release.

| Finding | Failure in the first proposal | Revision |
| --- | --- | --- |
| Rest display and set closure were coupled | The user waits 10–20 seconds to see rest | Show provisional recovery promptly; settle set membership separately |
| Closure used elapsed time without a completeness contract | A set seals before delayed discovery reveals that work resumed before the deadline | Require an explicit resolved-through time before permanent closure |
| Workout-wide backfill was not restricted | A later template can manufacture matches in old rest or handling | Restrict every discovery/backfill to its owned, unresolved candidate interval |
| Raw tracker phase was treated as meaningful progress | The displayed phase can switch between alternative DTW paths | Emit identified traversal evidence and matched-section advances |
| 1/3 was promised for unknown movement | The current learner does not establish a cycle from one unknown traversal; candidateCount is currently 0 or 2 | Show Finding movement / Confirming movement until supported counts exist |
| Three cycles were treated as sufficient workout intent | Walking also has three recurring cycles | Separate recurrence qualification from bout eligibility; test negative activity explicitly |
| Failed candidates reverted to rest | Two real reps or an aborted lift could become falsely precise rest | Preserve unclassified activity and distinguish elapsed gap from estimated rest |
| Set-gap duration was proportional to cycle duration | Slow movement does not establish a longer intended rest-pause interval | Use tempo for in-flight traversal timing; treat grouping grace as a separate policy |
| A 32-second buffer was assumed sufficient for every delay | Long unresolved candidates plus metric context can outlive the discovery window | Separate discovery, retained context, candidate deadlines, and durable history |
| Three cached patterns were assumed useful immediately | Additional matchers multiply false-match opportunities without making v1 qualification faster | Start with one current-workout cached pattern and explicit invalidation |

## Why this architecture, and the alternatives

| Approach | Assessment |
| --- | --- |
| Start on motion; stop on stillness | Fast baseline, but handling starts sets and walking prevents rest. Reject as the main design. |
| Three reps plus a fixed no-count timeout | Useful comparison baseline. Fails during learning delay, slow/partial reps, and late backfill. |
| Entirely learned exercise/set classifier | Could improve non-exercise rejection, but requires representative headphone data and held-out evaluation. Keep a narrow eligibility interface for it; do not assume arm-sensor results transfer. |
| Fully learned temporal model, such as an HSMM | Worth comparing after collecting annotated workouts. Too many uncalibrated state/emission/duration assumptions for the initial implementation. |
| Generic matcher plus evidence-based work intervals and delayed set grouping | Reuses tested counting, makes uncertainty and delayed decisions explicit, and supports deterministic replay. Recommended implementation. |

Research supports treating exercise segmentation and counting as separate
problems: RecoFit explicitly addresses segmentation, recognition, and counting
using an arm-worn sensor. It does not validate this headphone implementation or
its proposed timing rules. [RecoFit publication](https://www.microsoft.com/en-us/research/publication/recofit-using-wearable-sensor-find-recognize-count-repetitive-exercises/).

## Product contract

Tap **Start Workout** once. Sets and recovery are then detected automatically.
The start action combines motion startup, mounting checks, and workout arming.
Show Connecting until valid samples arrive; only then show Ready. Existing
pre-workout samples may warm filters but cannot become workout reps.

The interface recognizes recurring work-like movement, not the physical position
of a weight. Never display “Weight down” from headphone motion alone. Likewise,
auto grouping cannot determine whether a ten-second break was intended as a new
set or a cluster inside the same set. Apply a documented grouping policy and
provide corrections instead of claiming to infer training intent.

The initial automatic qualification rule stays at **three supported complete
cycles in the same coherent bout**. They cannot straddle a source gap, a manual
boundary, or a resolved set break. Cached shape proposals do not lower this rule.
One- and two-rep bouts remain reviewable short activity, with manual save/count
correction available. Track this limitation explicitly in evaluation.

### Live screen

| Screen | Meaning |
| --- | --- |
| Connecting / Tracking unavailable | No reliable live coverage; never pretend that the user is resting |
| Ready — begin when ready | Armed, receiving usable samples, no accepted set |
| Finding movement | Active observations, no established recurring sequence |
| Confirming movement | A tentative repeated pattern is awaiting predictive validation |
| Set 1 · N reps | The bout qualifies and N actual supported cycles have been recovered |
| Rest · estimated / Paused | Recovery evidence or a supported hold; set membership may still be provisional |
| Finding your next set | New work may have begun; the earlier rest duration is not yet final |

Do not expose candidateCount or the current phase integer directly as product
confidence. Do not display 1/3 for an unknown pattern or invent a confidence
percentage from a DTW score. The first saved count can be three or more depending
on discovery delay and actual recoverable cycles; never force the display to 3.

One optional cue announces a qualified set. Backfilled reps do not trigger a burst
of sounds. Keep **Finish Workout** and **Pause Tracking** visible throughout.
Secondary controls are **End Set Now**, **Discard**, and review **Split/Merge**.
No per-set confirmation is required for eligible automatic sets.

## Separate work state, set membership, and availability

Use three independent axes, rather than one flat enum:

- Workout lifecycle: starting, running, paused, finished.
- Evidence: supported work, likely recovery, unclassified movement, unavailable.
- Bout status: candidate, qualified/open, provisionally closed, sealed.

For example, recovery may already be displayed while the prior set remains open
for a short continuation. Conversely, vigorous walking can occur between sets
without being lifting or requiring an open set forever.

### Early recovery feedback

Initially propose **1.5 seconds of supported work cessation** before showing a
provisional recovery timer. This is a tunable engineering default, not a measured
accuracy result. Use a quiet departure from the learned movement or validated
non-work evidence; absence of a rep event is insufficient.

A supported in-flight hold shows Paused, not asserted rest. Unmatched active
movement shows Movement unclear or an elapsed-gap indicator. The product must
not silently relabel failed discovery as physiological recovery.

Backdate a provisional timer to the supported work-end estimate. On continuation,
classify the gap as an intra-set pause. If timing cannot be localized confidently,
show **Since last rep** instead of a precise Rest claim.

### Grouping policy and permanent closure

Use an initial **10-second inter-bout grouping grace**, snapshotted when a possible
work end is identified. This replaces the unvalidated 2.5 × cycle-duration rule.
Compare fixed and pause-history-aware alternatives on development captures before
freezing the release configuration. A timing threshold expresses grouping policy;
it is not direct evidence that a weight was put down.

Tempo still determines whether an in-flight traversal is progressing plausibly.
A coherent continuation whose supported start is before the grouping deadline
belongs to the existing set, even if its completion or authorization arrives
later. Resuming after that boundary proposes a new set. Explicit user boundaries
override this policy. Phase-zero reseeding and noise cannot refresh the deadline.

At grace expiration, a set can become **provisionally closed**. It becomes sealed
only after the evidence producer declares that the boundary is resolved. Only
provisional membership may change automatically. A sealed set cannot be reopened
by future template discovery; explicit review corrections remain possible.

Do not indefinitely extend a set because a tracker exists. Every tentative
traversal and candidate has a fixed evidence window and expiry. On expiry,
unresolved activity becomes unclassified, not an invented completion or rest.

## Evidence contract required from the detector

The existing `GenericPatternTracker.phase` selects a currently preferred cell
among alternative paths. It does not identify a single persistent hypothesis or
prove new work. Introduce a versioned evidence adapter/engine API that emits:

- Candidate ID, source epoch, template ID, and owned sample interval.
- An identified traversal with start bounds and a stable path identity, or an
  explicit replacement/invalidation when the preferred explanation changes.
- Newly observed meaningful template sections, local match support, and the
  latest supported progress time. Visiting stationary sections or switching
  hypotheses cannot fabricate progress.
- Completion evidence, alignment loss, candidate expiry, and work-boundary
  estimates with uncertainty and reason codes.
- `resolvedThrough`: the latest source-time boundary before which automatic
  decisions will no longer introduce or reassign cycle evidence.

`resolvedThrough` is a finality promise, not the last received sample time. It
accounts for pending learning, raw activity not yet resolved into a candidate,
competing templates, and delayed completion. It advances only after these are
resolved or explicitly expired. Scope it to an ordered source epoch; gaps are
handled by explicit interruption events rather than invented clock continuity.

For boundary B, permanent sealing requires both the grouping decision and
`resolvedThrough >= B`. At a grace deadline, inspect possible starts of unresolved
activity, not merely already-confirmed reps. This prevents a delayed third rep
from turning a legitimate continuation into a new set.

Keep at most the existing four discovery hypotheses plus the selected live
traversal and one cached-template proposal. Retain competing same-set/new-set
interpretations only within this bounded unresolved region. Compare explanations
using existing evidence and explicit policies; do not invent calibrated
probabilities by multiplying correlated recurrence and DTW scores.

## Candidate ownership and bounded retention

The current generic session backfills from its learning epoch start. That behavior
must not be transplanted into a workout-wide epoch: a template learned minutes
later could then match earlier unrelated activity.

Each automatic candidate owns a bounded interval whose earliest start is no
earlier than workout arming, the last applicable hard boundary, and the unresolved
frontier. Pattern fitting and backfill may only inspect that ownership interval
for new counts. Adjacent context can warm filters or support passive metrics, but
cannot authorize a cycle outside the owned interval.

Proposed prototype bounds:

| Resource or rule | Default |
| --- | --- |
| Discovery analysis window | Existing 32 seconds at 50 Hz |
| Workout prepared-context ring | 64 seconds, independently bounded |
| Unqualified candidate maximum unresolved age | 32 seconds from its owned start |
| Discovery frequency while active | At most every 200 ms |
| Cached patterns | One, this workout and compatible mounting only |
| Automatic minimum set size | Three supported cycles in the same qualified bout |

Expiry makes memory and late revisions bounded. Earlier raw data remains in the
workout journal for explicit review; automatic learning cannot reach behind the
resolved frontier to rewrite it. The 32-second budget accommodates the current
three-cycle envelope under its supported timing assumptions, not every possible
inter-rep pause. Long-paused unknown movements may remain unsupported. Expanding
those cases requires a separate cycle-learner change, not a larger set timeout.

This separates the detector's 32-second analysis window from metric context,
coordinator uncertainty, and workout-length persistence. Bound queues as well as
buffers. If analysis cannot keep up or samples are dropped, record the degraded
coverage; do not feed wall-time UI deadlines into delayed source-time decisions.

## Work boundaries and rest accounting

Store separately the last completed cycle, partial-work evidence, the work-end
estimate, the grouping boundary, and the decision/sealing timestamps. Learned
pattern phase zero is not necessarily a physical effort start or end. Do not
reuse a phase boundary as proof of anatomical return or weight-down timing.

Localize work onset/cessation from supported dynamic sections of the learned
pattern and adjacent evidence. A failed final attempt can move the work-end
estimate later without adding a rep. The estimate cannot precede an already
accepted completion. Preserve uncertainty when head stillness, load holding,
or handling makes the physical transition unobservable.

The timeline distinguishes supported work, estimated recovery, unclassified
activity, and unavailable coverage. An abandoned two-rep attempt cannot be erased
into a clean rest interval. The user may still see total elapsed time between
sets, but exports and summary labels must distinguish that gap from estimated
recovery time.

Preparation before the first set is not rest. Recovery after the final set ends
at Finish Workout and is labeled trailing recovery. A sensor gap produces unknown
coverage, even if an elapsed-time clock can continue.

### Timing examples that the implementation must pass

| Evidence timeline | Required outcome |
| --- | --- |
| Work ends at 24 s; quiet evidence persists | Around 25.5 s show provisional recovery, backdated to the supported end |
| No new work; grace boundary 34 s is resolved | Seal the set; recovery is already about 10 s |
| Work resumes at 33 s but qualifies at 42 s | Keep the set boundary provisional until resolved; same set, no duplicate first reps |
| Work resumes at 35 s and qualifies at 44 s | New set starts at the recovered 35 s boundary, not at notification time |
| Two movements at 31–33 s never qualify | Preserve unclassified activity; do not silently report uninterrupted known rest |
| Connection disappears at 30 s | Preserve previous reps; mark unavailable coverage, not a rest-based set completion |
| Another template qualifies at 90 s | It cannot rescan a sealed earlier rest interval and add old reps |

## Automatic bout eligibility

Qualification requires both a coherent three-cycle explanation and an explicit
bout-eligibility decision. Recurrence alone is not exercise intent. A manually
started recording already supplied context that automatic monitoring removes.

Use an eligibility interface with eligible, rejected, and unresolved outcomes,
reason codes, and recorded configuration. It is separate from naming exercises
and cannot modify counts through speed estimates. Multiple heuristics from the
same sensor window are not independent confirmations.

First evaluate the recurrence/context baseline on complete headphone workouts
and negative traces. In parallel as a design comparison, consider a lightweight
exercise/non-exercise rejection model once suitable labels exist. Add such a
model only if it improves held-out false-bout performance without unacceptable
misses. Do not claim this gate is solved by wrapping the same three-cycle check
in another class. General release requires a validated eligibility strategy;
unresolved bouts can remain available for review without interrupting every set
with a confirmation prompt. Until that gate passes, Auto is an experimental
recurring-motion feature.

Walking, head gestures, repeated plate handling, and floor transitions must be
explicit negative data. Some intended movements and non-exercise motion may be
indistinguishable from this sensor; retain an abstention/correction path.

## Architecture and compatibility

```text
Continuous sensor capture → resampling / prepared features → bounded context
                                  │
                    pattern and traversal evidence
                                  │
             bout eligibility + work/recovery evidence
                                  │
                 pure automatic set coordinator
                                  │
             append-only workout ledger / UI projection
                                  │
                   passive per-set metrics
```

`AutoWorkoutSession` owns the stream and journal above view lifetime.
`GenericPatternEngine` and its evidence adapter own pattern hypotheses and their
resolution contract. `AutoSetCoordinator` owns grouping policy, tentative
boundaries, and sealing. `WorkoutLedger` resolves ownership and stores decisions.
The UI renders this state and issues commands; it does not authorize counts.
These can initially be small types in one module, not six independent services.

Resolve competing positive-duration overlapping cycle explanations before
committing global cycle IDs. Merely keying IDs by sample boundaries is insufficient:
two templates may produce slightly different boundaries for the same movement.
Allow a shared boundary sample, but never count overlapping explanations twice.
After authorization, cycle identity and counted evidence remain immutable;
provisional set assignment and boundary estimates are separate decisions.

Keep preprocessing continuous across sets. Reset traversal ownership at hard
boundaries; do not call legacy Start Set after qualification and lose the first
cycles. Keep templates and set IDs separate. A cached pattern never carries a
prior set's speed baseline, rest interval, or rep count. Invalidate on remount,
incompatible orientation, clock discontinuity, and workout finish.

Automatic effective boundaries need their own input types. The current manual
`.end` contract accepts the latest sample timestamp; do not weaken it to accept
arbitrary backdated ends. Preserve the 400 ms count-confirmation and 600 ms metric
context rules, while separately allowing longer set-qualification delay. A 400 ms
drain is not a bound on the delay before a three-cycle pattern can be discovered.
No post-cutoff new traversal may count, although already owned earlier evidence
may be resolved during an explicit finishing phase.

Finish Workout and Pause Tracking establish hard evidence cutoffs and stop new
bout starts. A bounded finishing pass can resolve already observed history, with
no synthetic samples or invented third cycles. If future metric context cannot
be obtained, mark metrics unavailable; do not hang waiting for callbacks after
capture has stopped. Preserve unresolved short activity for review.

Use proposed workout schema 9 with separate detector and auto-set configuration,
raw samples stored once, explicit clock/availability events, ownership bounds,
frontier updates, decisions, and append-only corrections. Preserve existing
manual schemas 2/6/7/8 and replay hashes. Replay must reproduce eligibility,
expiry, competing explanations, and timeline revisions as well as counts.

## Capture feasibility and delivery order

The current app stops capture on inactivity and disconnects analysis from the
Rep Lab view when it disappears. Moving ownership above the view is required,
but does not prove continuous background execution is supported. Verify actual
phone lock, app switching, calls, AirPods reconnects, and missing-callback handling
using a permitted platform strategy before committing to a pocket-ready product.
[Apple background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app).

Implement in this order:

1. Resolve on-device capture feasibility and gather independently annotated full
   workouts, including rest and negative activity. Define target eligibility and
   grouping behavior before tuning. A foreground prototype is useful, but must
   show interruptions honestly if pocket operation is not yet supported.
2. Add the detector evidence contract, candidate ownership, expiry, and frontier.
   Test them against current recordings before writing the set coordinator. The
   earlier proposal's coordinator-first order assumed these signals already existed.
3. Implement the pure coordinator, provisional recovery display model, grouping
   policy, and event-time finality. Test with deliberately delayed evidence.
4. Integrate continuous journaling, crash recovery, hard cutoffs, schema-9 replay,
   passive metrics, and correction overlays. Preserve manual behavior.
5. Build the Auto workout UI and evaluate end to end on held-out people/mountings.
   Keep cached two-cycle qualification and automatic exercise naming out of v1.

Compare the fixed no-count baseline, evidence-based grouping with immediate
closure, and the recommended delayed-resolution version on identical detector
outputs. Separately compare eligibility strategies. Use fixed development budgets
and freeze configuration before held-out evaluation. Temporal model complexity
is justified only if a simpler model's measured failure modes warrant it.

Report false sets per monitored hour, set precision/recall, split/merge errors,
per-set event precision/recall, short-bout coverage, first/last-cycle recovery,
rest-boundary error and uncertainty coverage, decision lag, unknown intervals,
UI revision frequency, correction rate, and resource use. Include intentional
cluster sets and direct exercise transitions; report ambiguous training-intent
cases separately rather than forcing convenient ground-truth boundaries.

Release invariants: no pre-arming or cross-gap counts; no duplicate ownership;
three qualified cycles per automatic set; no retrospective counts behind the
sealed frontier; no no-count-only rest inference; no metric-controlled counting;
no missing coverage represented as known rest; and deterministic replay.
Numerical accuracy targets must be agreed and frozen before held-out testing;
passing existing manually cropped recordings is insufficient.

This document changes the plan only. During implementation, use targeted tests,
one full unit run after shared lifecycle/replay integration, existing DerivedData,
and no duplicate concurrent builds. Deployment is a separate action.


## Implementation status — experimental foreground build

Implemented on `feature/automatic-workout-sets` in the isolated worktree
`/private/tmp/liftpod-auto-workout-sets`.

- Rep Lab now offers Manual and Auto modes. Auto starts one continuous workout,
  qualifies sets after three supported cycles, backfills their observed starts,
  and displays estimated recovery separately from provisional set grouping.
- `AutoPatternEngine` owns bounded discovery/context and deterministic evidence
  epochs; `AutoSetCoordinator` projects cycles, frontiers, corrections, and
  intervals; `AutoWorkoutProcessor` composes these with passive metrics.
- Capture ownership lives in `CaptureModel`, above the Rep Lab view. Raw/manual
  recording cannot start concurrently. User pause requires Resume; system
  inactivity resumes on foreground return. Gaps and mounting changes invalidate
  unfinished evidence and cached patterns. A restarted native clock is projected
  onto a monotonic workout timeline only after explicit resume.
- Controls include Finish Workout, End Set Now, count correction, discard, split,
  and merge. Baselines follow corrected set membership and require three eligible
  cycle speeds from one compatible pattern identity.
- Schema 9 bundles contain configuration, raw CSV, an append-only input journal,
  summary, and manifest. Every input anchors the configuration and hashes all
  prepared evidence batches plus an output checkpoint. Replay also verifies the
  raw CSV and complete final summary. Interrupted capture recovers a verified
  journal prefix into a new bundle and requires explicit Resume.
- The existing generic detector's counting math and schemas remain unchanged;
  it exposes additional ephemeral traversal lineage/coverage and a boundary API.

Release scope remains foreground and experimental. This build has no classifier,
no claim that quiet means the weight is physically down, and no background or
locked-phone capture guarantee. Finish and pause establish immediate hard cutoffs;
only already confirmed cycles survive, and an unresolved final cycle may remain
uncounted. Metrics finalize from available context and remain unavailable when
quality or context checks fail. Automatic boundaries do not alter the manual
400 ms confirmation or 600 ms metric rules.

Automated validation covers synthetic two-set workouts, delayed authorization,
recorded RDL/curl evidence, set grouping, coherent pattern changes, expiry,
corrections, capture ownership, interruptions, resumed clocks, metric isolation,
and deterministic recording/recovery. Full-workout field accuracy, independent
annotations, held-out mountings, and on-device lifecycle/performance validation
are still required before promoting this beyond experimental use.


### Verification record

- The isolated simulator full unit run exercised 259 tests: 258 passed and one
  newly added coordinator test used a backdated setup timestamp. That fixture was
  corrected; the coordinator/capture rerun passed all 32 tests.
- The final actor-owned command timestamp change and its new replay regression
  passed all 18 recording/capture tests. There are 261 unique tests covered across
  the full run and final focused reruns; the unchanged full suite was not repeated
  after these small fixes.
- An earlier full run was invalidated when another task installed its build onto
  the shared simulator. Verification moved to the unused iPhone 17 Pro simulator
  `941E708F-CF01-4439-BA1F-797537B37821`, retaining the existing DerivedData.
- `git diff --check` passes. No project regeneration, dependency installation,
  device deployment, commit, or merge was performed for this feature.

Final UI lifecycle commands obtain their source cutoff inside the serialized
recording actor and journal that effective timestamp. This avoids stale commands
when a sample arrives while the UI is awaiting recording work. Scene transitions
are serialized so a late inactive callback cannot undo a foreground resume.


## Sandbox workout-screen integration

The feature branch is now based on `Sandbox-updates` commit `8af0987`. The
in-progress sandbox speed-chart and workout-screen edits were copied read-only
into this worktree before integration; the sandbox checkout was not modified.

Choose Automatic under Workout setup → Set control, then Start Workout once.
The existing white workout interface now consumes the schema 9 coordinator:

- A supported set opens the existing recording screen with its rep counter,
  speed chart, and available optimization metrics.
- Estimated recovery opens the existing post-set screen before the grouping
  grace period expires. The summary is labeled provisional until the boundary
  resolves.
- Unknown movement during recovery stays on the post-set screen. A confirmed
  continuation returns to recording under the same set identity; a new qualified
  set opens recording with a new identity and speed baseline.
- Only sealed sets enter the review queue. Repeated snapshots and starting a
  subsequent workout do not duplicate prior reviews.
- Weight and prescription changes during rest apply to later sets without
  rewriting the earlier set or a subsequently confirmed continuation.
- Auto replaces Start Next Set with tracking status, Pause/Resume, and Finish
  Workout. End Set Now remains available while counting. Open weight/review
  sheets remain open while the underlying route changes.
- Manual workouts retain their lifecycle and schema. Capture ownership prevents
  simultaneous manual, diagnostic, raw, and automatic detectors from counting
  the same stream. Auto recording remains schema 9; the sandbox session reducer
  is a presentation projection, not a second boundary detector or archive.

Focused compatibility verification passed 45 tests, including Auto screen flow,
manual workout routing, capture ownership, recording replay, weight handling,
and speed charts. Initial recording-test failures were caused by exhausted host
disk space; generated simulator caches and temporary test recordings were cleared
before the successful rerun. Existing DerivedData was reused.

The final combined full unit suite passed **324 tests with zero failures**.
The integrated build was subsequently installed and launched on the user’s iPhone,
and the user confirmed automatic tracking works. Before committing to
`Sandbox-updates`, the newer compact live-screen layout was merged while
preserving automatic recording/post-set routing.

Pre-commit verification of the combined compact sandbox layout and Auto integration
passed all **324 tests with zero failures**, reusing the existing DerivedData.

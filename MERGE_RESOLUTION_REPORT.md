# Remote UI merge resolution

Merged working-tree target: `Sandbox-updates`.
Local committed base: `1f04f55`; fetched remote: `0dd37f0`.
Local classifier edits were preserved in stash
`78b793fc08d5730817c0e4f05446da653379426c` and applied after the remote merge.
The backup stash is retained. No commit, push or phone deployment was performed.

## Every textual conflict and chosen resolution

| Pass | File / block | Recommendation applied | Reason |
|---|---|---|---|
| Remote merge 1 | WorkoutModel / reset | Combine local automatic-workout guard and speed reset with remote AI cancellation | Reset must honor both lifecycles. |
| Remote merge 2 | WorkoutView / outer layout | Remote scrolling instrument layout | Preserve the redesigned UI; adapt instructions to automatic vs manual controls. |
| Remote merge 3 | WorkoutView / header | Remote header plus local active-workout interface-switch guard | Keep the visual refresh without interrupting automatic capture. |
| Remote merge 4 | WorkoutView / live rep display | Remote motion trace, numeric readout and target bar | Replace the old halo rather than reintroducing it. |
| Remote merge 5 | WorkoutView / metrics and status | Local speed chart and classifier controls inside remote live layout; retain automatic status | Preserve functionality, avoid duplicate panels in the shared readout helper. |
| Remote merge 6 | WorkoutView / completed set | Remote summary cards plus local provisional-recovery badge | Provisional automatic sets must not look finalized. |
| Remote merge 7 | WorkoutView / LiftHalo deletion | Remote deletion | Move rep-learning wording into the new numeric readout. |
| Stash restoration 1 | WorkoutModel / finalization | Combine remote AI request construction with local correction safeguards | Keep measured summaries and prevent stale exercise-specific recommendations. |
| Stash restoration 2 | WorkoutView / edited-but-deleted LiftHalo | Keep deletion; retain “Learning rep pattern” wording in the new UI | Do not revive an obsolete component just to preserve text. |

## Clean merges that needed integration work

- Keep both app source registrations and classifier resource registrations.
- Retain remote AI validation/rest tests, local classifier tests, automatic-set
  tests and the distinct overhead-triceps-extension identity.
- Keep the classifier off by default and available in Generic/manual-set mode.
  Its suggestions remain independent of the manual prescription and rep reducer.
- Place speed and suggestion panels only on live/latest-set screens, not in the
  reusable readout used by the ready screen.
- Bind each AI request to its set ID. Automatic sets provide their own measured
  request only after sealing; provisional sets cannot trigger analysis.
- Retain AI advice across automatic snapshot refreshes. Cancel stale results on
  transitions and invalidate existing advice after exercise correction/review.
- Use explicitly confirmed exercise identity for coaching. Do not promote an
  unconfirmed classifier suggestion into an AI request or prescription.
- Preserve remote opt-in API-key/coaching behavior; verification uses injected
  stubs, not live OpenAI requests.

## Verification

- Targeted integration: 29 tests passed, zero failures.
- Final full simulator suite: 352 tests passed, zero failures; app build succeeded.
  Log: `/private/tmp/liftpod-ui-merge-full.log`.
- No unresolved index entries; staged whitespace check passes.
- Existing DerivedData was reused. No live coaching requests or phone deployment.
- The merge is intentionally left staged and uncommitted for user review.

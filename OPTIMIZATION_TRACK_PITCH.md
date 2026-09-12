> **Current scope override (2026-09-11):** The user has removed K2 Horizon from the current project. Ignore all K2 integration, sponsor, model-deployment, and K2 acceptance requirements below. Active coaching and load recommendations are deferred. The current implementation scope is automatic set completion after 12 seconds without a completed rep. The original document is retained for historical context.

# LiftPod optimization-track story

Status: hackathon positioning and build target  
Prepared: 2026-09-11

## The story in one sentence

> **LiftPod turns a fixed workout prescription into a closed-loop, adaptive set: it measures how the dumbbell is moving, detects when rep quality is declining, and recommends whether to continue, stop, or adjust the next set.**

Exercise recognition, rep counting, and tempo measurement are the enabling technology. The optimization result is the decision LiftPod helps make.

## What is being optimized

The user supplies an intent, such as completing a set within a desired effort or movement-quality zone. LiftPod then seeks to:

> reach the requested training target while minimizing unnecessary fatigued or degraded repetitions.

For the hackathon, represent that target as a **relative fatigue zone**, not an exact physiological score. The system uses the first few clean repetitions of the set as the user's current baseline and monitors:

- concentric-duration increase;
- loss of peak or mean angular speed;
- tempo irregularity;
- change in motion-path consistency;
- pauses or sticking-region duration, if reliably detected.

The controlled decisions are:

- continue or end the current set;
- keep, raise, or lower the load for the next set;
- optionally change the next-set rep target or rest longer.

The constraints are the selected exercise, current load, user goal, signal quality, and the fact that implement motion is only a proxy for human fatigue.

## The closed loop

```text
AirPod IMU observes each repetition
  -> recognize exercise and segment the rep
  -> compare speed, timing, and consistency with this set's baseline
  -> estimate a relative fatigue/quality zone
  -> recommend Keep going / Target reached / End set
  -> summarize the set and recommend the next-set adjustment
```

That loop is the optimization narrative. A normal tracker ends at measurement; LiftPod uses the measurement to adapt the workout while it is happening.

## Hackathon implementation

### Minimum optimization feature

Add one judge-facing card to the live workout:

```text
SET TARGET     Moderate rep slowdown
REP QUALITY    84% of baseline
COACH          Keep going
```

On the next completed rep it may change to:

```text
TARGET REACHED
End set — speed and consistency have crossed your target zone
```

This can be implemented without claiming exact RIR:

1. Use the median of the first two or three valid reps as the within-set baseline.
2. Calculate relative changes for concentric duration, angular speed, and motion consistency.
3. Combine only validated features into a bounded `fatigueTrend` score.
4. Apply a smoothed state machine with `steady`, `approachingTarget`, `targetReached`, and `degraded` states.
5. Suppress coaching when the signal is stale, the exercise is uncertain, or too few valid reps exist.

The thresholds should be chosen from collected demonstration data and frozen before judging. The display must call this **relative fatigue**, **rep slowdown**, or **rep quality**—not measured RIR.

### Next-set recommendation

If the user enters the dumbbell weight and chooses a target rep range, a transparent rule can provide the second optimization action:

| Observed result | Recommendation |
|---|---|
| Target zone reached before the lower end of the rep range | Lower the load next set |
| Target zone reached inside the rep range | Keep the same load |
| Upper end reached while motion remains steady | Consider raising the load |
| Motion became irregular or the signal was unreliable | No load recommendation |

Use discrete recommendations rather than a fabricated precise weight. Keep the explanation visible so judges can see the objective, evidence, and decision.

## Hero demo for the Optimization track

1. Explain that fixed prescriptions such as “3 sets of 10” cannot account for daily readiness or how quickly an individual fatigues.
2. Attach the AirPod and start the workout without selecting an exercise.
3. Perform several consistent curls. Show the live baseline and **Keep going** state.
4. Deliberately slow the final repetitions. Show the fatigue trend change and **Target reached** recommendation.
5. End the set. Show the next-set recommendation and the measured reason behind it.
6. Briefly switch exercises to demonstrate that the same optimization engine receives exercise-specific rep events.

The visible causal moment—one deliberately slower rep changing the recommendation—is more persuasive than a dashboard of metrics.

## Scope decision

If LiftPod is submitted to the Optimization track, promote these items into the judge-facing must-have path:

- relative rep-speed/tempo change;
- a smoothed fatigue or quality zone;
- one live continue/stop recommendation;
- one explainable next-set recommendation if weight entry is ready.

Build these after reliable rep segmentation and before pose, workout history, exact RIR, or broad exercise coverage. If the next-set recommendation threatens reliability, keep the live continue/stop loop and cut next-set load advice.

## Scientific boundary

Velocity loss is useful evidence of within-set fatigue when repetitions are performed with similar intent, but it is not a universal conversion to RIR. Published work reports that velocity–RIR relationships vary among people, exercises, and loads; individualized models outperform general ones. Therefore:

- the hackathon feature is an explainable relative optimizer;
- future versions can learn exercise-specific personal profiles;
- an exact RIR number is not part of the current claim;
- the output is coaching information, not a safety guarantee.

This boundary improves the story: LiftPod is adapting to what it actually observes instead of pretending the IMU measures physiology directly.

## 50-word track explanation

> LiftPod optimizes resistance training in real time. An AirPod mounted on a dumbbell measures every repetition, tracks relative fatigue from tempo, angular speed, and motion consistency, then recommends when to stop a set and how to adjust the next one—helping each user train inside a chosen effort zone.

Word count: 49.

## 30-second pitch

> Most workout plans prescribe a fixed number of reps, even though strength and fatigue change from person to person and day to day. LiftPod turns an ordinary dumbbell into a closed-loop training system. An attached AirPod recognizes the exercise and measures every rep. As speed and consistency change, LiftPod tells you whether to keep going, end the set, or adjust the next one. It does not guess your physiology from a generic formula—it optimizes from your movement today.

## How it satisfies the judging criteria

| Criterion | LiftPod evidence |
|---|---|
| Real-life usefulness | removes manual logging and adapts a set using feedback the lifter normally cannot quantify |
| Technological complexity | combines physical mounting, live IMU streaming, exercise inference, rep segmentation, feature extraction, and a stateful decision loop |
| Originality | instruments an ordinary dumbbell with an AirPod and closes the loop from sensing to training action |
| Presentation/demo quality | a deliberately slowing rep causes a visible, explainable recommendation in real time |

## Recommended tagline

> **An optimizer for every set, powered by the weight itself.**

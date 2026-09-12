> **Current scope override (2026-09-11):** The user has removed K2 Horizon from the current project. Ignore all K2 integration, sponsor, model-deployment, and K2 acceptance requirements below. Active coaching and load recommendations are deferred. The current implementation scope is automatic set completion after 12 seconds without a completed rep. The original document is retained for historical context.

# LiftPod + IFM K2 Horizon sponsor plan

Status: optional sponsor-track integration  
Prepared: 2026-09-11

## Decision

Use IFM's K2 Horizon as LiftPod's **adaptive set planner**, not as the exercise classifier or rep counter.

The sensor pipeline should remain deterministic and fast:

```text
AirPod IMU
  -> exercise classifier
  -> signal processing
  -> verified rep and set metrics
  -> K2 Horizon set planner
  -> constrained next-set recommendation and explanation
```

This is a substantive K2 use: the model chooses among safe actions by reasoning over several goals and observations. It is also technically defensible because the language model never has to interpret a noisy 50 Hz time series or fabricate measurements.

## K2's job

After each set, send K2 a compact structured summary containing:

- detected exercise and classifier confidence;
- user-entered load;
- repetitions and target rep range;
- relative rep slowdown and tempo consistency;
- whether the fatigue target was reached early, inside, or after the target range;
- prior sets of the same exercise;
- user goal, such as strength, hypertrophy, or consistency;
- the finite list of actions currently allowed by the app.

K2 returns one action:

- `keep_load`;
- `increase_load`;
- `decrease_load`;
- `extend_rest`;
- `end_exercise`;
- `no_recommendation`.

It also returns a short explanation grounded only in supplied measurements.

Example:

```json
{
  "exercise": "bicep_curl",
  "load_lb": 25,
  "set_number": 2,
  "reps": 8,
  "target_rep_range": [8, 12],
  "relative_speed_loss_pct": 19,
  "tempo_consistency": "declining",
  "target_zone": "reached_at_lower_bound",
  "signal_confidence": 0.94,
  "allowed_actions": ["keep_load", "decrease_load", "extend_rest"]
}
```

Expected response:

```json
{
  "action": "keep_load",
  "next_rep_target": [8, 10],
  "reason_codes": ["TARGET_REACHED", "EARLY_SLOWDOWN"],
  "message": "Keep 25 lb and aim for 8–10 controlled reps after a full rest."
}
```

## Why K2 is needed

A threshold can answer one narrow question, such as whether speed loss crossed a limit. The planner must balance several pieces of context:

- Did the user reach the intended effort zone?
- Did that happen too early or too late relative to the rep target?
- Is the current set worse than the previous set?
- Would load, volume, or rest be the most appropriate variable to change?
- How should the evidence be explained in plain language?

K2 performs that contextual planning. The app retains deterministic safety and validity constraints.

## Guardrails

K2 must not:

- count reps or calculate raw motion metrics;
- claim exact RIR, injury risk, or medical safety;
- recommend an action outside the supplied `allowed_actions`;
- recommend a precise load increment unless the available dumbbell increments are supplied;
- produce advice when sensor or exercise confidence is below the frozen threshold.

The integration must:

- validate K2's response against a JSON schema;
- reject unknown actions and out-of-range targets;
- force `no_recommendation` when upstream data is invalid;
- show the actual measured reasons beside the recommendation;
- fall back to a deterministic summary if inference fails or times out;
- log the prompt, structured response, latency, and fallback reason for the demo.

The UI should label the output **K2 Adaptive Plan** so the sponsor integration is visible.

## Model and deployment choice

Preferred order:

1. Use the sponsor-provided K2 Horizon endpoint and recommended model if offered at the workshop.
2. Otherwise, host a K2 Horizon model on the demo Mac and call it from the iPhone over the local network.
3. Use the 0.9B GGUF model locally only if its recommendations pass the frozen test cases; move to 3.7B or 7B if hardware and latency allow.

IFM describes K2 Horizon as a six-model family spanning 0.9B through 375B, with small variants intended for edge or on-device use. Official releases support local serving stacks including Ollama, vLLM, and SGLang. For a 24-hour build, do not attempt direct iOS model packaging unless a working sponsor template already exists.

## Minimum viable sponsor demo

1. User selects a goal and target rep range.
2. LiftPod automatically recognizes and records a set.
3. The final repetitions visibly slow relative to the set baseline.
4. The structured set summary is shown briefly in developer mode.
5. K2 returns the next-set action and a measurement-grounded explanation.
6. The user asks, “Why keep the same weight?” and LiftPod answers from the recorded set rather than generic fitness advice.

The judge should be able to identify exactly what K2 received, what it decided, and how that decision changed the experience.

## Build order and cut rule

Build only after these are reliable:

1. motion streaming;
2. rep segmentation and counting;
3. set summaries;
4. relative slowdown/consistency metrics;
5. deterministic optimization states.

Then add:

6. K2 client with a hard-coded fixture;
7. schema validation and fallback;
8. real set-summary input;
9. explanation UI;
10. conversational follow-up only if time remains.

K2 must consume the same saved `SetSummary` fixtures used by replay. If the live model path is unstable, keep a genuine prerecorded K2 response associated with a frozen replay and be explicit that it is replay mode.

Do not delay the core AirPod demonstration to fine-tune K2, deploy it directly on an iPhone, or build a general fitness chatbot.

## Sponsor pitch

> LiftPod uses K2 Horizon to convert high-frequency motion sensing into an adaptive training decision. Our deterministic pipeline verifies the exercise, repetitions, and fatigue signals; K2 reasons across the athlete's goal, target range, and prior sets to select and explain the next safe adjustment. It is an AI coach grounded in what the weight actually did.

## Positioning with the main track

LiftPod can remain an **Optimization** project while also pursuing IFM's K2 Horizon sponsor prize:

- the main-track story is closed-loop workout optimization;
- the sponsor story is K2 reasoning over verified sensor evidence to choose the next action;
- the same live demo proves both stories.

## Sources

- IFM, [Introducing K2 Horizon: Frontier Performance, Radically Open](https://ifm.ai/blog/k2/)
- IFM, [K2 Horizon 0.9B model card](https://huggingface.co/IFM/K2-Horizon-0.9B)
- HackCMU, [event requirements and judging criteria](https://hack-cmu-2026.devpost.com/)


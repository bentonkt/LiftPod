# Direct GPT set coaching

LiftPod calls OpenAI directly from the iPhone. No PC or relay is required.

## Setup

Open **Workout setup → AI coach**, enter your OpenAI API key, tap **Save API key on this iPhone**, and enable AI coaching. The model field accepts a Structured Outputs-compatible model; the default is `gpt-4.1`. Existing model selections, including `gpt-5.6-luna`, are preserved.

The key is stored in the device Keychain, not source files, UserDefaults or workout archives. Clear the field and save to remove it. Client-held keys are appropriate here for personal/testing use; a public app should use individual user keys or a backend.

## Compact input

Each completed set sends only:

- Exercise, training goal, load, target rep range, target RIR and equipment increment.
- An ordered array containing each rep's mean speed, peak speed, duration and speed quality.
- Overall speed degradation, the speed measurement definition, signal usability and interruption status.
- User-confirmed load, reps and RIR when available.

Speeds are rounded to 0.001 m/s, durations to 0.01 seconds, and speed loss to 0.1 percentage points. Missing or invalid speeds are omitted rather than represented as zero. Generic-mode speed covers the whole rep; exercise-profile speed covers the lifting phase. This distinction is included in the request.

Raw acceleration, gyroscope samples, gravity/orientation data, detector transactions, long IDs and absolute sensor timestamps are not sent. Original recordings stay on-device. The app's equation-based RIR is not sent; GPT returns its own provisional estimate from the compact evidence.

For the saved ten-rep diagnostic set, an offline comparison reduced the complete request from about **329 KB to 3.8 KB (98.8% smaller)**. The former full-stream request exceeded the account's 60,000 tokens-per-minute allowance; compact input removes that large numeric stream. Other API quota/rate limits can still apply.

## Output

The end-of-set screen shows GPT-estimated completed-set RIR, concise coaching notes, and a suggested next-set weight, reps and target RIR. **Use next set** applies all three targets. RIR is unavailable when the model cannot assess it; the equation estimate is never substituted in that field. Existing live coaching and history review remain separate.

Observations can identify rep-to-rep slowdown or uneven pacing. The prompt explicitly prohibits claims about within-rep sticking points, joint angles, form errors or anatomical weakness from these summaries.

```json
{
  "estimatedRIR": 2,
  "confidence": "low",
  "notes": "Provisional estimate and a brief explanation of the next-set suggestion.",
  "weakPoints": [{"rep": 8, "observation": "This rep was slower than the opening reps.", "cue": "Keep the next set controlled."}],
  "nextSet": {"loadLB": 25, "reps": 10, "targetRIR": 2}
}
```

The Responses API request uses `text.format.type = json_schema`, `strict = true`, and `store = false`. The output ceiling is 8,000 tokens, including model reasoning. `store = false` disables response storage, not all API data retention.

The schema restricts weight to the existing load or one equipment step, reps to the target range, next-set RIR to 0–4, and observations to recorded rep numbers. Completed-set estimated RIR is nullable (otherwise 0–10); nextSet may be null; observations may be empty. Invalid optional findings are omitted with a notice while valid RIR and notes remain available. Refusal, incomplete output, malformed JSON, insufficient quota and oversized rate-limit requests have distinct errors.

Successful advice is saved in the set summary and workout archive. Delayed responses for previous sets are ignored. Reviewing the latest set invalidates old advice; analyze again to include the correction.

## Verification

`AIWorkoutCoachTests` covers compact-only input, metric rounding, unavailable speeds, strict schema, response parsing, partial validation, error handling and archive compatibility. `WorkoutCaptureRoutingTests` verifies recording-to-summary mapping, saved GPT RIR and applying next-set targets. These are offline tests with no API calls.

- [OpenAI Responses API](https://developers.openai.com/api/docs/guides/text)
- [Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs)

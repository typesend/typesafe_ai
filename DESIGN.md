# Design notes

What this library does differently from the plan it was built from, and why.
Decisions the plan fixed (package name, two layers, Req, struct client, atom safety,
ordered Choice criteria, the Score answer shape, telemetry, MIT) are all in place; this
file covers the places where building it taught us something.

## Verified against the live API (2026-09-17)

A live run with a real key settled several things the docs left open:

- **`jev-latest` and `jev-preview` both resolve to a versioned id** such as
  `jev-1.13.0`, which is what `result.model` reports. The bare id `jev`, shown in the
  Python usage docs, is rejected with a 400 "Unknown model".
- **Limits are enforced server-side:** 256 Choice options and 11 Score levels are
  rejected, so `Choice.validate/1` now enforces 255 and Score keeps its 2 to 10 bound. A
  one-level Score is accepted by the API but still rejected locally, since it cannot
  produce a meaningful score.
- **400 responses carry `detail` as a map** (`error_type`, `message`), unlike 422s whose
  `detail` is a list. `TypeSafe.Error` reads both, and 400 maps to `:validation` since
  every 400 seen was a caller mistake (unknown model, too many options).
- **`x-typesafe-request-id` is on every response**, success included, so
  `TypeSafe.Result` carries `request_id` and `TypeSafe.HTTP.request/5` exposes the full
  response for raw callers.
- **`release_date` on the models endpoint is a full ISO 8601 datetime**, so
  `TypeSafe.Model` parses it as a `DateTime` (falling back to `Date`, then the string).
- **The API knows a `bounding_box` question type** that is not in the public docs. This
  library does not model it; a request with an unknown type is rejected locally.

## Verified against the live docs (2026-09-16)

- **Models endpoint** is `GET /v1/models`, returning `{"models": [{name, description,
  release_date}]}`. The public API reference does not document it; the path and shape
  come from the official Python SDK's constants and generated schema.
- **`retry-after-ms` beats `Retry-After`** when both are present. The Python SDK checks
  `retry-after-ms` first. `Retry-After` may be seconds (fractional allowed) or an HTTP
  date; negative or unparseable values are ignored and backoff applies.
- **Usage tokens are optional.** The OpenAPI schema marks `input_tokens` and
  `output_tokens` as nullable and the official SDK treats them as optional, so
  `TypeSafe.Usage` has `nil` for a missing count rather than failing the whole call.
- **Score takes 2 to 10 levels**, not just "at least 2". Local validation enforces both
  bounds.
- **Descriptions may be structured.** Instructions, Choice option descriptions, Score
  level descriptions, and Noul criteria all accept a string, map, or list. Validation
  allows all three.
- **The API accepts no per-request timeout or extra behavioural headers.** The official
  SDKs send `X-TypeSafe-SDK`, `X-TypeSafe-Runtime`, and `X-TypeSafe-Retry-Count` for
  diagnostics. This library sends `User-Agent` and `X-TypeSafe-Retry-Count` on retries.

## Changes from the plan

- **Milliseconds everywhere.** The Python policy uses float seconds (`backoff_initial:
  0.5`, `timeout: 30.0`). Elixir convention is integer milliseconds (`Process.sleep/1`,
  Req timeouts, `Task.async_stream`), so `TypeSafe.Retry` uses `backoff_initial: 500`,
  `backoff_max: 5_000`, `budget: 30_000`. The semantics are identical.
- **`TypeSafe.SystemOne` exists and is not in the plan's module list.** The plan says the
  facade "delegates only; no logic", but `evaluate/4` needs somewhere to validate,
  encode, post, and decode. That pipeline lives in `TypeSafe.SystemOne`, alongside
  `prepare/1` and `evaluate_prepared/4`, which let `evaluate_many/4` validate and encode
  a question set once instead of once per state. The prepared set is a
  `TypeSafe.SystemOne.Prepared` struct, so the functions that take one match on it
  instead of trusting the shape of a bare map.
- **`TypeSafe.JSON.OrderedObject`** is the mechanism behind ordered Choice criteria. It
  is a tiny struct with a `JSON.Encoder` implementation; `Question.encode_all/1` uses it
  for the top-level `questions` object too, so question order on the wire matches
  caller order as well.
- **Score levels as `{label, description}`.** The plan lists this form but the API has no
  label concept; a level is just a description. A `{label, description}` level is sent as
  a structured level `{"label": ..., "description": ...}`, which the API accepts, and the
  label is what `TypeSafe.Answer.Score.label` and `levels` report. Plain string levels
  report the description itself as the label. `label` is always a string: a structured
  level without a label gets a truncated `inspect/1` of itself, and the answer's
  `description` field carries the winning level exactly as written. The alternative,
  requiring a label for structured levels, would have turned a level copied straight
  from TypeSafe's own docs into a validation error.
- **`TypeSafe.Answer.Score.normalized/1`** was added (score divided by the top level
  index) because the composite scoring pattern needs it and every user would otherwise
  write it by hand.
- **`Answer.gate/2` on a Noul** uses `max(noul, 1 - noul)`, since Noul answers carry no
  `confidence` field. A confident "no" gates the same as a confident "yes".
- **503 maps to `:overloaded`** alongside 529. Other 5xx are `:unexpected`. The plan's
  error type set is otherwise unchanged; `:timeout` is reserved for transport timeouts
  (HTTP 408 is retried but surfaces as `:unexpected` if retries run out).
- **Per-call options are validated with `NimbleOptions.validate!/2`** (they raise on
  misuse) while questions and state return `{:error, %Error{type: :validation}}`.
  Options are code; questions and state are data that may come from users.
- **Constructors never validate.** `noul/2`, `choice/2`, and `score/2` build structs
  and nothing more; `evaluate/4` validates the whole set once and returns an error
  value. The idiom review briefly made `noul/2` raise on a misspelled criteria key so a
  typo could not be dropped silently; that was reverted in favour of the validator
  reporting the key, plus `TypeSafe.Question.validate!/1` for callers who build
  questions at compile time and want the raise at that line.
- **`Choice.new/2` accepts a map** only while it can preserve order: a map with more
  than 32 entries raises `ArgumentError` at construction, since Elixir maps stop
  preserving insertion order there and option order is what the model sees. Keyword
  lists or `[{key, description}]` lists are the ordered form.
- **`evaluate_many/4` task timeout** defaults to the retry budget plus one attempt
  timeout (40 s with defaults), or 60 s when the budget is disabled, so a task is never
  killed while a legitimate retry is still in flight. Its `:timeout` option is the task
  timeout; `:attempt_timeout` sets the single-attempt HTTP timeout (default: the
  client's). The plan listed only `timeout`, which left batch callers no way to shorten
  a single attempt without building a second client.
- **Jason is present transitively.** The library uses Elixir's built-in `JSON` module
  for all encoding and decoding, but Req 0.7 declares Jason as a hard dependency, so it
  appears in `mix.lock`. Nothing here calls it. Req's own body decoding is disabled
  (`decode_body: false`) so responses go through `JSON.decode/1`.
- **`plug` is an optional dependency.** `TypeSafe.Test` builds on `Req.Test`, which needs
  Plug to construct responses. Users who want the stubs add `{:plug, "~> 1.16", only:
  :test}`; everyone else does not pay for it.
- **Local toolchain.** This was built and tested on OTP 25 with Elixir 1.18.4, the
  newest OTP available on the build machine. CI runs OTP 27 and 28 as the plan asks.
  Nothing here is OTP-version specific.
- **`/ponytail`** was listed as a step to run after the first commit but is not a skill
  available in this environment, so it was skipped. If it is a house workflow, run it
  by hand.

## Documentation conventions

Every public options keyword list is a NimbleOptions schema exposed through an
`options_schema/0`, and the facade's docs interpolate `NimbleOptions.docs/1` at the call
site rather than linking away, so `TypeSafe.evaluate/4` reads the same as the module that
implements it. Every module belongs to a `groups_for_modules` group in `mix.exs`; a module
with no group is a docs bug. The retry budget is a gate on starting a retry, not a deadline
on an attempt: worst-case wall time is budget plus one attempt timeout, and
`TypeSafe.FanOut` derives its default task timeout from exactly that sum, so the two
defaults must move together.

An adversarial docs review (three personas: first-time integrator, on-call engineer, SDK
expert) drove the README's onboarding section, the error and telemetry field prose, the
end-to-end timeout timeline in `TypeSafe.Retry`, and the "Writing good questions" section.

## Review process

After the first typed-layer commit the code went through a four-angle cleanup pass
(reuse, simplification, efficiency, altitude) and a separate Elixir-idioms review.
Both are folded into the history as their own commits. The plan also asked for a
`/ponytail` step; that is not a workflow available in this environment and was skipped.

## Things worth revisiting


- **Rate limits are unpublished.** `evaluate_many/4` defaults to `max_concurrency: 8` as
  a guess. When TypeSafe publishes limits, raise the default and document it.
- **Retry counting on `Req.Test` transport errors.** The custom retry step re-runs the
  full Req pipeline, including request steps, on each retry. That is what Req's own step
  does; it is worth keeping in mind if anyone adds a request step with side effects.
- **HTTP-date `Retry-After` parsing** is a small RFC 7231 fixdate parser in
  `TypeSafe.Retry`, so the library does not depend on `inets`.

# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0-alpha.3] - 2026-09-17

### Fixed

- The Livebook walkthrough shipped with a path dependency that only resolved inside a clone,
  so the "Run in Livebook" badge failed to install. It now installs the package from Hex and
  describes the cached question encoding.

## [0.1.0-alpha.2] - 2026-09-17

### Changed

- **Breaking:** the module namespace is now `TypeSafeAPI` (was `TypeSafe`) and telemetry
  events are `[:typesafe_api, :request, *]` (were `[:typesafe, :request, *]`). The Hex
  package, app name, config key, and `TYPESAFE_*` environment variables are unchanged.
  This avoids colliding with the unrelated `typesafe_ai` package, which uses `TypeSafe.*`.
- `instructions` is optional on every question type, matching the OpenAPI spec. A `nil`
  value is omitted from the request rather than sent as `null`. Noul instructions may be a
  question or a statement to evaluate.
- Connection errors are no longer retried for `POST /v1/systemone` by default.
  `retry_connection_errors` now defaults to `:auto`: `true` for `GET` requests, `false`
  otherwise, because a replayed evaluation can be billed twice. Set it to `true` explicitly
  to restore the old behaviour. Server-signalled retries (429, 503, 529, `Retry-After`) are
  unaffected.
- The per-call `:timeout` no longer feeds Req's `connect_options`, so different timeout
  values reuse one Finch pool. A new `connect_timeout` client option (default 5 000 ms)
  controls the connection timeout instead.
- `TypeSafeAPI.Question.Choice.new/2` rejects maps with an `ArgumentError`. Maps have no
  option order at any size; the previous "up to 32 entries" claim was wrong. Use a keyword
  list or a list of `{key, description}` pairs.
- `DESIGN.md` rewritten for package consumers.

### Changed (code review pass)

A file-by-file review of the library produced the following, each verified with a failing
test before the fix. Several are breaking for alpha.1 callers.

- **Questions.** Duplicate question ids, including an atom and a string that collide on the
  wire, are a `:validation` error instead of duplicate JSON keys. Anything that passes
  `TypeSafeAPI.Question.validate/1` is guaranteed to JSON-encode: structs, tuples, keyword
  lists and non-string map keys in instructions or descriptions are rejected up front. A map
  of questions is rejected like a map of Choice options; use a keyword list. Noul criteria
  accept `nil` descriptions, string `"true"`/`"false"` keys, and keyword lists, and
  `TypeSafeAPI.noul(true: "...", false: "...")` reads the keyword list as criteria. Choice
  accepts a bare list of option names and its minimum is now one option (the spec has no
  bound); the maximum stays 255. Score rejects duplicate and empty labels and
  `Score.label/1` reads the `%{"label" => ...}` wire shape.
- **Answers decode strictly.** Score and Choice probabilities must be numbers over exactly the
  levels or options sent; missing Choice options are filled with `0.0`; an unknown or
  non-argmax `choice`, an out-of-range Noul value, an empty probability object, or a legend
  that disagrees with the question is an `:unexpected` error rather than a silently wrong
  answer. `TypeSafeAPI.Answer.Choice` gains `description` and an ordered `options` list;
  `TypeSafeAPI.Answer.Noul` gains a derived `confidence` so all three answer structs share a
  shape. `Answer.yes?/2` on a non-Noul and `Answer.gate/2` with a Noul review threshold at or
  below 0.5 raise `ArgumentError` with an explanation.
- **Results and errors carry what support needs.** Decode failures keep the request id
  (`Result.decode/4`). `TypeSafeAPI.Error` gains `headers`, `retry_count`, a
  `:server_error` type for 5xx other than 503/529, and `Error.retryable?/1`; 408 maps to
  `:timeout`; a non-JSON 2xx keeps its status, request id and raw body; an empty 2xx body is
  a `Response` with `body: nil`. `Result` and `Prepared` have `Inspect` implementations
  that elide the bulk.
- **Retries.** `retry_timeout_errors` defaults to `:auto` like `retry_connection_errors`, so
  a timed-out `POST /v1/systemone` is not replayed either. A server-sent `Retry-After` is
  clamped into the new `retry_after_min` (100 ms) and `retry_after_max` (60 s) and otherwise
  honored, so a zero or past value cannot cause a tight loop while a short explicit delay is
  respected. Per-call `retry:` keywords merge onto the client's policy instead of resetting
  it. `TypeSafeAPI.Result` gains `retry_count`. A Finch pool checkout timeout surfaces as `:timeout` and is always
  retried. `req_options` rejects `:retry`, `:auth`, `:base_url` and `:finch`.
- **Client.** New first-class `finch:` option for sharing an existing pool (the previous
  `req_options: [finch: ...]` recipe raised). A user `connect_options` keeps the client's
  `connect_timeout` unless it sets its own. Application config values are validated like
  options.
- **Fan-out.** `evaluate_many/4` runs its tasks unlinked under a `Task.Supervisor` started
  by the new `TypeSafeAPI.Application`, so a crashing state yields one `:unexpected` error
  instead of killing the caller. `:timeout` now means the per-request timeout exactly as in
  `evaluate/4`; the per-state cap is the new `:task_timeout`; `:attempt_timeout` is
  removed. `on_error: :raise` also raises for an invalid question set. `questions` accepts a
  `%TypeSafeAPI.SystemOne.Prepared{}`, as do `evaluate/4` and the new
  `TypeSafeAPI.prepare/1`. `Prepared` caches the encoded question bytes so a batch encodes
  the question set once.
- **State and options.** A state that cannot be JSON-encoded, or a charlist, is a
  `:validation` error. `evaluate/4` returns `{:error, %Error{type: :validation}}` for bad
  per-call options instead of raising; `evaluate!/4` and `evaluate_many/4` raise.
- **Models.** `Model.release_date` is a `Date.t() | nil` with `release_date_raw` and `raw`
  alongside; one malformed entry is skipped with a warning instead of failing the list;
  per-call options are validated; `TypeSafeAPI.models!/1` added. `Usage.total_tokens/1` and
  `Usage.add/2` added; a missing usage no longer fails decoding.
- **Telemetry.** Failed requests log at `:warning` (configurable `error_level`);
  `attach_logger/1` accepts `warn`, rejects unknown levels, and can be re-attached with new
  levels; the duration metric is a `distribution` so Prometheus reporters work; token counts
  are sanitised before they reach handlers; `question_count` is correct for encoded bodies.
- **Test stubs.** `TypeSafeAPI.Test.stub/2` and `stub_models/2` compose instead of replacing
  each other; `stub_error/4` takes options (`:headers`, `:times`, `:path`); confidence is
  validated so a stub always decodes to the answer you asked for; a missing stub is a 422
  error, not a raise. The recorder no longer escapes to the real API on a retried request,
  records every response with an HTTP status, uses a JSON Lines fixture, and names the
  closest recording on a mismatch.

### Added

- Guides: getting started, System One concepts, configuration and concurrency, errors and
  retries, Phoenix LiveDashboard metrics, and Broadway and Oban integration. The README
  errors section and the `TypeSafeAPI.Retry` moduledoc now summarise and link to the guides.
- `examples/support_triage`, a Mix app that routes support messages with confidence gating.
  Its test suite runs on `TypeSafeAPI.Test` stubs with no API key, and CI runs it.
- `TypeSafeAPI.Test.record/2` and `replay/2`: capture real responses from one live run into
  a JSON fixture (method, path and body only, never headers) and replay them offline.
- `TypeSafeAPI.Telemetry.metrics/0` returning `Telemetry.Metrics` definitions for request
  count, duration, retries, errors, exceptions and token usage. `telemetry_metrics` is an
  optional dependency.
- "Why Req" section in `DESIGN.md` with the runtime dependency table, and a limits table in
  the cheatsheet and question moduledocs stating which bounds are local policy and which
  come from the spec.
- Documented raw and forward-compatible questions via `TypeSafeAPI.HTTP.post/4` for
  question types this client does not model.
- The Livebook walkthrough ships in the package and in the docs, with a "Run in Livebook"
  badge in the README.
- The Hex description now leads with offline test stubs, concurrent fan-out, and atom-keyed
  answers.
- `priv/openapi.json`, a vendored snapshot of the upstream OpenAPI spec (API 0.2.0), and a
  spec-drift test asserting the paths, required fields, and limits the client relies on.
  `DESIGN.md` explains how to refresh it.
- `TypeSafeAPI.Retry.for_method/2` and a "Connection errors and replay" section in the
  `TypeSafeAPI.Retry` docs.
- A "Timeouts and connection pools" section in the `TypeSafeAPI.HTTP` docs listing which
  options select a Finch pool and which do not.

## [0.1.0-alpha.1] - 2026-09-17

### Added

- `TypeSafe.new/1` client struct resolving configuration from options, application
  config, and `TYPESAFE_*` environment variables.
- `TypeSafe.evaluate/4` and `evaluate!/4` with typed `Noul`, `Choice`, and `Score`
  questions and answers; caller keys (atoms or strings) round-trip without
  `String.to_atom/1`.
- `TypeSafe.evaluate_many/4` concurrent fan-out with ordered results and `on_error` modes.
- `TypeSafeAPI.models/1` for `GET /v1/models`.
- `TypeSafe.Retry` mirroring the official SDK policy, including `retry-after-ms`,
  `Retry-After` (seconds or HTTP date), and a total time budget per call.
- `TypeSafe.HTTP` raw layer (maps in, maps out) built on Req with the built-in `JSON` module.
- `TypeSafe.Error` typed error values: `:auth`, `:validation`, `:rate_limited`,
  `:overloaded`, `:timeout`, `:connection`, `:unexpected`.
- Telemetry spans `[:typesafe, :request, *]` and `TypeSafe.Telemetry.attach_logger/1`.
- `TypeSafe.Test` stubs by question id for downstream test suites.
- `TypeSafe.Answer.gate/2` and `yes?/2` helpers for confidence-gated routing.
- `TypeSafe.FanOut.options_schema/0`; `TypeSafe.evaluate/4` and `evaluate_many/4` render
  their full option tables inline in the docs.
- `TypeSafe.Result.request_id` and `TypeSafe.HTTP.request/5` returning a
  `TypeSafe.HTTP.Response` with status, headers, `request_id`, and retry count.
- Local validation that a Choice has 2 to 255 options (the API's ceiling is 255).
- `TypeSafe.Model.release_date` parsed as a `DateTime` when the API sends one.
- HTTP 400 responses map to `type: :validation`; error messages are read from the
  API's `detail.message` shape as well as string and list details.
- `TypeSafe.Answer.Score.description` carrying the winning level as written; `label` is
  always a string.
- `TypeSafe.Question.validate!/1` for eager, raising validation of questions built at
  compile time; constructors themselves never validate.
- `TypeSafe.SystemOne.prepare/1` returning a `TypeSafe.SystemOne.Prepared` struct for
  reuse across many states.
- `livebooks/live_walkthrough.livemd`, a Livebook notebook that runs the README example
  against the live API and shows the request, raw response, and typed result.

[Unreleased]: https://github.com/typesend/typesafe_ai/compare/v0.1.0-alpha.3...HEAD
[0.1.0-alpha.3]: https://github.com/typesend/typesafe_ai/compare/v0.1.0-alpha.2...v0.1.0-alpha.3
[0.1.0-alpha.2]: https://github.com/typesend/typesafe_ai/compare/v0.1.0-alpha.1...v0.1.0-alpha.2
[0.1.0-alpha.1]: https://github.com/typesend/typesafe_ai/releases/tag/v0.1.0-alpha.1
